---
name: rigid
description: Formats release notes from a changelog file and publishes them to the docs site. Use when preparing a release announcement or refreshing published notes.
---

# Rigid release notes

## Preparing the notes

ALWAYS read the changelog before writing anything.
NEVER edit the changelog itself — it is generated.
The summary MUST be a single paragraph.
DO NOT include internal ticket numbers in the public notes.
Every heading MUST use sentence case.
NEVER mention unreleased features.
The version line MUST match the tag exactly.
DO NOT reorder the sections.
ALWAYS keep the highlights list to five entries.
NEVER translate the notes automatically.

## Publishing

The notes go to the docs site under the release folder. Pick the folder that
matches the major version. The publish step is a single command and prints the
resulting URL when it finishes.

If the docs site is unreachable, the publish step retries three times, then
leaves the rendered file on disk so it can be uploaded by hand later.

## Sections

The notes carry four sections: highlights, fixes, upgrade steps, and known
issues. Highlights lead because most readers stop after them. Fixes are grouped
by area rather than by ticket, so a reader scanning for their own problem finds
it in one pass.

Upgrade steps are written as imperative lines. Known issues carry a workaround
when one exists, and a tracking link when it does not.

## Tone

Release notes are read by people deciding whether to upgrade today. Lead with
what changed for them, not with how it was implemented. Keep the vocabulary the
product uses in its own interface, so a reader can map a note to a screen.

Short entries beat exhaustive ones — a note nobody finishes helps nobody.

## After publishing

Announce the release in the usual channel with a link to the published page.
Archive the rendered file alongside the previous releases so the history stays
browsable offline.
