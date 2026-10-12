#!/bin/bash
# Prepares an iDared 32bit release, or a new build of the current one, all
# locally so you can check it before pushing anything:
#
# 1. Sets the app's version in iphone/Config.xcconfig, the only place it's
#    set. A new version starts again at build 1; the current version gets
#    its next build number.
# 2. Updates CHANGELOG-iDared32bit.md:
#    - New version: renames the NEXT section to the version. If there isn't
#      one, it adds a section drafted from the commits since the last
#      release's tag, for you to rewrite, and stops there (see below).
#    - New build: moves what's in NEXT, if anything, into the version's
#      section, under the same headings, and updates its date.
# 3. Commits those two files: "Set app version to VERSION (Build N)".
# 4. Tags the commit vVERSION. For a new build, the old tag is deleted and
#    created again on the new commit.
#
# It never pushes; it tells you what to push.
#
# If it drafted the changelog, it doesn't commit or tag. Rewrite the section,
# then commit and tag with the commands it prints.
#
# Usage: dev-scripts/prepare-release.sh VERSION
# For example: dev-scripts/prepare-release.sh 1.3.23
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 VERSION  (for example: $0 1.3.23)" >&2
    exit 1
fi
VERSION="$1"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: \"$VERSION\" isn't a version like 1.3.23." >&2
    exit 1
fi

cd "$(dirname "$0")/.."
XCCONFIG=iphone/Config.xcconfig
CHANGELOG=CHANGELOG-iDared32bit.md
TAG="v$VERSION"

OLD_VERSION=$(sed -n 's/^MARKETING_VERSION = //p' "$XCCONFIG")
OLD_BUILD=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$XCCONFIG")
if [ -z "$OLD_VERSION" ] || ! [[ "$OLD_BUILD" =~ ^[0-9]+$ ]]; then
    echo "Error: $XCCONFIG doesn't set MARKETING_VERSION and" \
        "CURRENT_PROJECT_VERSION." >&2
    exit 1
fi

# The commit must hold only this script's changes, so nothing may be staged,
# and the two files must be as committed.
if ! git diff --cached --quiet; then
    echo "Error: there are staged changes. Commit or unstage them first." >&2
    exit 1
fi
if ! git diff --quiet -- "$XCCONFIG" "$CHANGELOG"; then
    echo "Error: $XCCONFIG or $CHANGELOG has uncommitted changes." >&2
    exit 1
fi

if [ "$VERSION" = "$OLD_VERSION" ]; then
    BUMP=1
    BUILD=$((OLD_BUILD + 1))
    if ! grep -q "^## v$VERSION " "$CHANGELOG"; then
        echo "Error: $CHANGELOG has no section for v$VERSION." >&2
        exit 1
    fi
else
    BUMP=
    BUILD=1
    if grep -q "^## v$VERSION " "$CHANGELOG"; then
        echo "Error: $CHANGELOG already has a section for v$VERSION." >&2
        exit 1
    fi
    if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
        echo "Error: tag $TAG already exists." >&2
        exit 1
    fi
fi

# 1. The version and build number.
awk -v version="$VERSION" -v build="$BUILD" '
    /^MARKETING_VERSION = / { print "MARKETING_VERSION = " version; next }
    /^CURRENT_PROJECT_VERSION = / {
        print "CURRENT_PROJECT_VERSION = " build
        next
    }
    { print }
' "$XCCONFIG" > "$XCCONFIG.tmp"
mv "$XCCONFIG.tmp" "$XCCONFIG"

# 2. The changelog.
HEADING="## v$VERSION ($(date +%Y-%m-%d))"
DRAFTED=
if [ -n "$BUMP" ]; then
    # NEXT's lines go at the end of the same heading's list (a line like
    # "Compatibility:") in the version's section. Headings the section doesn't
    # have are added at its end, and NEXT itself is removed.
    awk -v version="v$VERSION" -v heading="$HEADING" '
        function flush_heading(    i) {
            if (cur in extra) {
                # Before the blank lines that end the list.
                printf "%s", extra[cur]
                done[cur] = 1
            }
            for (i = 0; i < blanks; i++) print ""
            blanks = 0
        }
        function flush_section(    i, h) {
            flush_heading()
            for (i = 1; i <= nheads; i++) {
                h = heads[i]
                if (!(h in done) && h != "") {
                    print h
                    print ""
                    printf "%s", extra[h]
                    print ""
                }
            }
            if ("" in extra && !("" in done)) {
                printf "%s", extra[""]
                print ""
            }
        }
        # First pass: collect NEXT, by heading.
        FNR == NR {
            if ($0 == "## NEXT") { innext = 1; h = ""; next }
            if (innext && /^## /) { innext = 0 }
            if (!innext) next
            if (/^[^-[:space:]].*:$/) {
                h = $0
                if (!(h in seen)) { seen[h] = 1; heads[++nheads] = h }
                next
            }
            if ($0 == "") next
            if (!(h in extra) && h == "") heads[++nheads] = ""
            extra[h] = extra[h] $0 "\n"
            next
        }
        # Second pass: write the changelog without NEXT, merged into the
        # version section.
        $0 == "## NEXT" { skip = 1; next }
        skip && /^## / { skip = 0 }
        skip { next }
        index($0, "## " version " ") == 1 {
            print heading
            insec = 1
            cur = ""
            next
        }
        insec && /^## / {
            flush_section()
            insec = 0
        }
        insec {
            if ($0 == "") { blanks++; next }
            if (/^[^-[:space:]].*:$/) {
                flush_heading()
                cur = $0
                print
                next
            }
            for (; blanks > 0; blanks--) print ""
            print
            next
        }
        { print }
        END { if (insec) flush_section() }
    ' "$CHANGELOG" "$CHANGELOG" > "$CHANGELOG.tmp"
    mv "$CHANGELOG.tmp" "$CHANGELOG"
    CHANGELOG_DONE="Moved the NEXT section of $CHANGELOG, if any, into v$VERSION's."
elif grep -q '^## NEXT$' "$CHANGELOG"; then
    awk -v heading="$HEADING" '/^## NEXT$/ { print heading; next } { print }' \
        "$CHANGELOG" > "$CHANGELOG.tmp"
    mv "$CHANGELOG.tmp" "$CHANGELOG"
    CHANGELOG_DONE="Renamed the NEXT section of $CHANGELOG to v$VERSION."
else
    # Otherwise it's drafted from the commit subjects since the last iDared
    # 32bit release's tag (touchHLE's own tags are v0.x). Commits by anyone but
    # you (going by git's user.email) are credited, and fixup and version bump
    # commits are left out.
    LAST_TAG=$(git describe --tags --abbrev=0 --match 'v[1-9]*' 2>/dev/null || true)
    if [ -n "$LAST_TAG" ]; then
        RANGE="$LAST_TAG..HEAD"
        SINCE="since $LAST_TAG"
    else
        RANGE="HEAD"
        SINCE="in the whole history, as no earlier release tag was found"
    fi
    ME=$(git config user.email || true)
    DRAFT=$(git log --no-merges --reverse --format='%s%x09%an%x09%ae' "$RANGE" |
        awk -F '\t' -v me="$ME" '
            $1 ~ /^(fixup|squash|amend)! / { next }
            $1 ~ /^Set app version to / { next }
            { line = "- " $1; if ($3 != me) line = line " (by " $2 ")"; print line }
        ')
    COUNT=$(printf '%s' "$DRAFT" | grep -c '^- ' || true)

    SECTION=$(mktemp)
    {
        echo "$HEADING"
        echo
        echo "<!-- Draft of the commits $SINCE. Rewrite it for people using iDared"
        echo "32bit: group it under Compatibility, Usability, Documentation and Other,"
        echo "leave out what isn't worth mentioning, and don't name specific games for"
        echo "fixes. Then delete this comment. -->"
        echo
        if [ -n "$DRAFT" ]; then
            printf '%s\n' "$DRAFT"
        else
            echo "- (No commits found.)"
        fi
        echo
    } > "$SECTION"

    # Insert it before the first existing version section.
    awk -v section="$SECTION" '
        !inserted && /^## / {
            while ((getline line < section) > 0) print line
            inserted = 1
        }
        { print }
        END { if (!inserted) while ((getline line < section) > 0) print line }
    ' "$CHANGELOG" > "$CHANGELOG.tmp"
    mv "$CHANGELOG.tmp" "$CHANGELOG"
    rm -f "$SECTION"
    CHANGELOG_DONE="Added a v$VERSION section to $CHANGELOG, drafted from $COUNT commit(s) $SINCE."
    DRAFTED=1
fi

SUBJECT="Set app version to $VERSION (Build $BUILD)"
TAG_MSG1="iDared 32bit $VERSION"
TAG_MSG2="Source for iDared 32bit $VERSION. The App Store build ($VERSION, build $BUILD) was built from this code."
TAG_MSG3="Licensed under the Mozilla Public License 2.0."
BRANCH=$(git symbolic-ref --short -q HEAD || echo "<branch>")

echo "Set iDared 32bit's version to $VERSION, build $BUILD (it was $OLD_VERSION, build $OLD_BUILD), in $XCCONFIG."
echo "$CHANGELOG_DONE"

if [ -n "$DRAFTED" ]; then
    cat <<EOF

Nothing was committed or tagged, as the changelog is a draft.

Next:
  1. Rewrite the v$VERSION section of $CHANGELOG.
  2. Commit: git commit -m "$SUBJECT" $XCCONFIG $CHANGELOG
  3. Tag it:
       git tag -a $TAG -m "$TAG_MSG1" -m "$TAG_MSG2" -m "$TAG_MSG3"
  4. Build it and submit it with Xcode.
  5. Push the branch and the tag:
       git push <remote> $BRANCH
       git push <remote> $TAG
  6. Publish a GitHub release for the tag, using
     dev-scripts/release-notes-template.md.
EOF
    exit 0
fi

# 3. The commit.
git commit -q -m "$SUBJECT" -- "$XCCONFIG" "$CHANGELOG"

# 4. The tag. A new build moves it to the new commit.
MOVED=
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
    OLD_TAG=$(git rev-parse "$TAG")
    OLD_TAG_COMMIT=$(git rev-parse --short "$TAG^{commit}")
    git tag -d "$TAG" > /dev/null
    MOVED=1
fi
git tag -a "$TAG" -m "$TAG_MSG1" -m "$TAG_MSG2" -m "$TAG_MSG3"

echo "Committed \"$SUBJECT\" as $(git rev-parse --short HEAD)."
UNDO="git tag -d $TAG; git reset --keep HEAD~1"
if [ -n "$MOVED" ]; then
    echo "Deleted tag $TAG (it was on $OLD_TAG_COMMIT) and created it again on the new commit."
    TAG_PUSH="git push --force <remote> $TAG"
    UNDO="$UNDO; git update-ref refs/tags/$TAG $OLD_TAG"
else
    echo "Created tag $TAG."
    TAG_PUSH="git push <remote> $TAG"
fi

cat <<EOF

Nothing has been pushed. Next:
  1. Check it: git show; git show $TAG
     To undo it all: $UNDO
  2. Build it and submit it with Xcode.
  3. Push the branch and the tag:
       git push <remote> $BRANCH
       $TAG_PUSH
  4. Publish a GitHub release for the tag, using
     dev-scripts/release-notes-template.md. For a new build, update the
     release's build number instead.
EOF
