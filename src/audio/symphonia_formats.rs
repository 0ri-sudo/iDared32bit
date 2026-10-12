/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! Quick-and-dirty decoding of miscellaneous formats (MP3, AAC) to linear PCM.
//!
//! This should be the only module in touchHLE that makes use of [symphonia].
//! For AAC, Only the LC profile and MPEG-4 container format are supported (see
//! feature list in Cargo.toml).

use std::io::Cursor;
use symphonia::core::audio::{AudioSpec, Channels, Position};
use symphonia::core::codecs::audio::well_known::{
    CODEC_ID_AAC, CODEC_ID_ADPCM_IMA_QT, CODEC_ID_ADPCM_IMA_WAV, CODEC_ID_ALAC, CODEC_ID_MP3,
    CODEC_ID_PCM_S16LE,
};
use symphonia::core::codecs::audio::{AudioCodecParameters, AudioDecoder};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::packet::Packet;
use symphonia::core::units::{Duration, Timestamp};

use super::CompressedFormat;

/// PCM data decoded from an miscellaneous format file.
pub struct SymphoniaDecodedToPcm {
    /// 16-bit little-endian PCM samples, grouped in frames (one sample per
    /// channel in each frame).
    pub bytes: Vec<u8>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Channel count.
    pub channels: u32,
    /// The compressed format it was decoded from, if any.
    pub compressed_format: Option<CompressedFormat>,
}

pub fn decode_symphonia_to_pcm(file: Cursor<Vec<u8>>) -> Result<SymphoniaDecodedToPcm, ()> {
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    // If this failed, the container format is not supported.
    let mut probed = symphonia::default::get_probe()
        .probe(
            &Default::default(),
            mss,
            Default::default(),
            Default::default(),
        )
        .map_err(|_| ())?;

    let track = probed
        .tracks()
        .iter()
        .find(|t| {
            if let Some(codec_params) = &t.codec_params {
                if let Some(audio_codec_params) = codec_params.audio() {
                    audio_codec_params.codec == CODEC_ID_AAC
                        || audio_codec_params.codec == CODEC_ID_ADPCM_IMA_WAV
                        || audio_codec_params.codec == CODEC_ID_ADPCM_IMA_QT
                        || audio_codec_params.codec == CODEC_ID_ALAC
                        || audio_codec_params.codec == CODEC_ID_MP3
                        || audio_codec_params.codec == CODEC_ID_PCM_S16LE
                } else {
                    false
                }
            } else {
                false
            }
        })
        .ok_or(())?;
    let track_id = track.id;

    // Not sure why this would fail, maybe an unusual AAC track.
    let audio_codec_params = track.codec_params.as_ref().unwrap().audio().unwrap();
    let compressed_format = match audio_codec_params.codec {
        CODEC_ID_AAC => Some(CompressedFormat::Aac),
        CODEC_ID_MP3 => Some(CompressedFormat::Mp3),
        CODEC_ID_ALAC => Some(CompressedFormat::Alac),
        _ => None,
    };
    let mut decoder = symphonia::default::get_codecs()
        .make_audio_decoder(audio_codec_params, &Default::default())
        .map_err(|_| ())?;

    let mut out_pcm = Vec::<u8>::new();
    let mut audio_spec: Option<AudioSpec> = None;
    {
        let mut tmp_raw_s16_buf: Option<Vec<u8>> = None;
        loop {
            let packet = match probed.next_packet() {
                Ok(packet) => match packet {
                    Some(packet) => packet,
                    // "If Ok(None) is returned, the media has ended and
                    // no more packets will be produced until the reader
                    // is seeked to a new position."
                    None => break,
                },
                // Assume I/O errors can only mean end-of-file, because the
                // entire file is in-memory.
                Err(symphonia::core::errors::Error::IoError(_)) => break,
                Err(_) => return Err(()),
            };

            if packet.track_id != track_id {
                continue;
            }
            let Ok(decoded_packet) = decoder.decode(&packet) else {
                break;
            };

            // For some reason, the "audio spec" (number of channels etc)
            // is reported per-packet? This is weird because it must be the same
            // for all of them.
            let audio_spec = audio_spec.get_or_insert_with(|| decoded_packet.spec().clone());
            assert_eq!(audio_spec, decoded_packet.spec());

            // Note that this assumes every packet's buffer's capacity is the
            // same, which is a dubious assumption, but Symphonia's own example
            // code does it, so maybe it's fine?
            let tmp_raw_s16_buf = tmp_raw_s16_buf
                .get_or_insert_with(|| Vec::with_capacity(decoded_packet.capacity()));
            tmp_raw_s16_buf.clear();
            decoded_packet.copy_bytes_to_vec_interleaved_as::<i16>(tmp_raw_s16_buf);

            out_pcm.extend_from_slice(tmp_raw_s16_buf);
        }
    }
    let audio_spec = audio_spec.ok_or(())?;
    Ok(SymphoniaDecodedToPcm {
        bytes: out_pcm,
        sample_rate: audio_spec.rate(),
        channels: audio_spec.channels().count().try_into().unwrap(),
        compressed_format,
    })
}

/// Decodes MP3 that an app parses itself and streams through an audio queue.
pub struct Mp3StreamDecoder(Box<dyn AudioDecoder>);

impl Mp3StreamDecoder {
    pub fn new() -> Self {
        let mut params = AudioCodecParameters::new();
        params.for_codec(CODEC_ID_MP3);
        let decoder = symphonia::default::get_codecs()
            .make_audio_decoder(&params, &Default::default())
            .unwrap();
        Mp3StreamDecoder(decoder)
    }

    /// For when the app jumps to another part of the stream.
    pub fn reset(&mut self) {
        self.0.reset();
    }

    /// Decodes `data` to 16-bit PCM, returning it with its sample rate and
    /// channel count, or [None] if `data` isn't a run of whole MP3 frames.
    pub fn decode(&mut self, data: &[u8]) -> Option<(Vec<u8>, u32, u32)> {
        // Data from files touchHLE decoded itself is already PCM.
        let (_, sample_rate, channels) = mp3_frame_header(data)?;
        let mut rest = data;
        while !rest.is_empty() {
            rest = &rest[mp3_frame_header(rest)?.0..];
        }

        let mut out_pcm = Vec::new();
        let mut tmp_raw_s16_buf = Vec::new();
        let mut rest = data;
        while !rest.is_empty() {
            let (len, _, _) = mp3_frame_header(rest).unwrap();
            let packet = Packet::new(0, Timestamp::ZERO, Duration::ZERO, &rest[..len]);
            rest = &rest[len..];
            // A bad frame is skipped, as a device would.
            if let Ok(decoded) = self.0.decode(&packet) {
                tmp_raw_s16_buf.clear();
                decoded.copy_bytes_to_vec_interleaved_as::<i16>(&mut tmp_raw_s16_buf);
                out_pcm.extend_from_slice(&tmp_raw_s16_buf);
            }
        }
        Some((out_pcm, sample_rate, channels))
    }
}

/// Decodes AAC or ALAC packets that an app parses itself and streams through
/// an audio queue.
pub struct PacketStreamDecoder(Box<dyn AudioDecoder>);

impl PacketStreamDecoder {
    /// AAC-LC, configured by the magic cookie if there is one.
    pub fn new_aac(sample_rate: u32, channels: u32, cookie: Option<&[u8]>) -> Option<Self> {
        let mut params = AudioCodecParameters::new();
        params.for_codec(CODEC_ID_AAC).with_sample_rate(sample_rate);
        params.with_channels(if channels == 1 {
            Channels::Positioned(Position::FRONT_CENTER)
        } else {
            Channels::Positioned(Position::FRONT_LEFT | Position::FRONT_RIGHT)
        });
        if let Some(config) = cookie.and_then(audio_specific_config) {
            params.with_extra_data(config.into());
        }
        Self::with_params(&params)
    }

    /// ALAC, configured by the magic cookie, or Apple's usual settings if
    /// there isn't one.
    pub fn new_alac(
        sample_rate: u32,
        channels: u32,
        bit_depth: u8,
        frames_per_packet: u32,
        cookie: Option<&[u8]>,
    ) -> Option<Self> {
        let config = match cookie {
            Some(cookie) => alac_specific_config(cookie)?.to_vec(),
            None => {
                let mut config = frames_per_packet.to_be_bytes().to_vec();
                // Version, bit depth, pb, mb, kb, channels, max run.
                config.extend_from_slice(&[0, bit_depth, 40, 10, 14, channels as u8, 0, 255]);
                // Max frame bytes and average bit rate: unknown.
                config.extend_from_slice(&[0; 8]);
                config.extend_from_slice(&sample_rate.to_be_bytes());
                config
            }
        };
        let mut params = AudioCodecParameters::new();
        params
            .for_codec(CODEC_ID_ALAC)
            .with_extra_data(config.into());
        Self::with_params(&params)
    }

    fn with_params(params: &AudioCodecParameters) -> Option<Self> {
        let decoder = symphonia::default::get_codecs()
            .make_audio_decoder(params, &Default::default())
            .ok()?;
        Some(PacketStreamDecoder(decoder))
    }

    /// For when the app jumps to another part of the stream.
    pub fn reset(&mut self) {
        self.0.reset();
    }

    /// Decodes the `packets` (offsets and sizes) in `data` to 16-bit PCM,
    /// returning it with its sample rate and channel count, or [None] if no
    /// packet could be decoded.
    pub fn decode(&mut self, data: &[u8], packets: &[(u64, u32)]) -> Option<(Vec<u8>, u32, u32)> {
        let mut out_pcm = Vec::new();
        let mut tmp_raw_s16_buf = Vec::new();
        let mut spec = None;
        for &(offset, size) in packets {
            let Some(bytes) = usize::try_from(offset)
                .ok()
                .and_then(|start| data.get(start..start.checked_add(size as usize)?))
            else {
                continue;
            };
            let packet = Packet::new(0, Timestamp::ZERO, Duration::ZERO, bytes);
            // A bad packet is skipped, as a device would.
            if let Ok(decoded) = self.0.decode(&packet) {
                spec.get_or_insert((decoded.spec().rate(), decoded.spec().channels().count()));
                tmp_raw_s16_buf.clear();
                decoded.copy_bytes_to_vec_interleaved_as::<i16>(&mut tmp_raw_s16_buf);
                out_pcm.extend_from_slice(&tmp_raw_s16_buf);
            }
        }
        let (sample_rate, channels) = spec?;
        Some((out_pcm, sample_rate, channels.try_into().unwrap()))
    }
}

/// The AudioSpecificConfig in an AAC magic cookie, which on iOS is an MPEG-4
/// ES descriptor, maybe in an `esds` atom.
fn audio_specific_config(cookie: &[u8]) -> Option<&[u8]> {
    let mut rest = match cookie.windows(4).position(|w| w == b"esds") {
        // Skip the atom's name, version and flags.
        Some(at) => cookie.get(at + 8..)?,
        None => cookie,
    };
    loop {
        let (&tag, after_tag) = rest.split_first()?;
        // The length is in 7-bit pieces, with the top bit meaning "more".
        let mut len = 0usize;
        let mut header = 0;
        loop {
            let &byte = after_tag.get(header)?;
            len = (len << 7) | usize::from(byte & 0x7f);
            header += 1;
            if byte & 0x80 == 0 || header == 4 {
                break;
            }
        }
        let body = after_tag.get(header..)?;
        match tag {
            // ES descriptor: ID, flags, then optional fields.
            0x03 => {
                let flags = *body.get(2)?;
                let mut skip = 3;
                if flags & 0x80 != 0 {
                    skip += 2;
                }
                if flags & 0x40 != 0 {
                    skip += 1 + usize::from(*body.get(skip)?);
                }
                if flags & 0x20 != 0 {
                    skip += 2;
                }
                rest = body.get(skip..)?;
            }
            // Decoder config: object type, stream type, buffer size, rates.
            0x04 => rest = body.get(13..)?,
            // Decoder specific info, which is the AudioSpecificConfig.
            0x05 => return body.get(..len),
            _ => return None,
        }
    }
}

/// The 24-byte ALACSpecificConfig in an ALAC magic cookie, which may be in
/// `frma` and `alac` atoms.
fn alac_specific_config(mut cookie: &[u8]) -> Option<&[u8]> {
    for atom in [b"frma", b"alac"] {
        if cookie.get(4..8) == Some(&atom[..]) {
            cookie = cookie.get(12..)?;
        }
    }
    cookie.get(..24)
}

/// The length, sample rate and channel count of the MPEG Layer III frame
/// `data` starts with, if it starts with one that fits in it.
fn mp3_frame_header(data: &[u8]) -> Option<(usize, u32, u32)> {
    const MPEG1_KBPS: [u32; 15] = [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
    ];
    const MPEG2_KBPS: [u32; 15] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];

    let &[b0, b1, b2, b3, ..] = data else {
        return None;
    };
    // Frame sync and Layer III.
    if b0 != 0xFF || b1 & 0xE0 != 0xE0 || (b1 >> 1) & 3 != 1 {
        return None;
    }
    // 0 is MPEG-2.5, 2 is MPEG-2, 3 is MPEG-1, 1 is reserved.
    let version = (b1 >> 3) & 3;
    let bitrate_index = usize::from(b2 >> 4);
    let sample_rate_index = usize::from((b2 >> 2) & 3);
    if version == 1 || bitrate_index == 0 || bitrate_index == 15 || sample_rate_index == 3 {
        return None;
    }
    let (kbps, sample_rate, coefficient) = match version {
        3 => (
            MPEG1_KBPS[bitrate_index],
            [44100, 48000, 32000][sample_rate_index],
            144,
        ),
        2 => (
            MPEG2_KBPS[bitrate_index],
            [22050, 24000, 16000][sample_rate_index],
            72,
        ),
        _ => (
            MPEG2_KBPS[bitrate_index],
            [11025, 12000, 8000][sample_rate_index],
            72,
        ),
    };
    let padding = u32::from((b2 >> 1) & 1);
    let len = (coefficient * kbps * 1000 / sample_rate + padding) as usize;
    let channels = if b3 >> 6 == 3 { 1 } else { 2 };
    (len <= data.len()).then_some((len, sample_rate, channels))
}
