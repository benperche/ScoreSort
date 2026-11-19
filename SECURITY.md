# Security policy

## Supported versions

Only the **latest release** of ScoreSort gets security fixes. ScoreSort updates itself through Sparkle, so the fix for a problem is a new release; please update before reporting.

## Reporting a problem

Please report security problems **privately**, not in a public issue:

- Use GitHub's **private vulnerability reporting**: the "Report a vulnerability" button on this repository's [Security tab](https://github.com/benperche/ScoreSort/security).

Include what you found, the ScoreSort version (ScoreSort ▸ About ScoreSort), your macOS version, and the steps that show it. ScoreSort is maintained by one person in their spare time, so expect a reply within a couple of weeks rather than days.

## What's in scope

ScoreSort works on PDF files on your own Mac. The areas that matter most:

- **The command line and MCP server** (`ScoreSort mcp`) that AI assistants use: anything that lets an assistant read files outside the folders shared in Settings ▸ AI Assistants (other than a path it was given), write over files without `--overwrite`, or replace an original it was working from.
- **Opening PDFs or images** that crash ScoreSort or make it write somewhere unexpected.
- **Updates**: anything that would let an update be installed without Sparkle's signature check.
- **Settings ▸ AI Assistants ▸ Connect to Claude**, which edits Claude's settings file.
