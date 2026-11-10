# Memory storage

The native CLI exposes four memory tools. Documents live in the active profile's `memory/` directory: `~/.fx/memory/` by default, or `$FX_HOME/memory/` when the profile is moved.

| Tool | Arguments | Result |
| --- | --- | --- |
| `write_memory` | `content`, `filename`, optional `frontmatter` object | Replaces the document and returns its canonical filename in a confirmation |
| `list_memory` | None | Sorted JSON array of filenames |
| `read_memory` | `filename` | Complete Markdown, including frontmatter |
| `query_memory` | `query` object | Sorted JSON array of matching filenames |

Filenames are single leaves, with `.md` appended when omitted. Paths, dotfiles, control characters, and names longer than 200 bytes before the suffix are rejected. Documents are limited to 8 MiB. Writes replace the entire document; they do not merge metadata or resolve concurrent edits.

## Frontmatter and queries

Pass the Markdown body without an existing frontmatter block. The writer encodes the separate `frontmatter` object as YAML. Values may be strings, numbers, booleans, nulls, or arrays containing only those scalar types. Nested maps and arrays are rejected. Strings and keys are quoted and escaped rather than interpolated into YAML.

Query keys are combined with AND. A null query value tests whether the key exists, including when its stored value is null. Other query values must be single scalars. They match an equal stored scalar or an equal member of a stored array. Strings and booleans are not coerced to numbers. Numeric comparisons preserve decimal precision. An empty query matches every valid document, including documents without frontmatter.

The reader accepts flat YAML mappings with quoted or plain scalars and flow or block scalar sequences. It rejects duplicate keys, nested data, aliases, tags, and multiline scalar syntax. Querying fails on malformed or unsupported frontmatter rather than returning partial matches. Reading a document still returns its raw Markdown when its metadata cannot be decoded.

## Ownership and permissions

`memory.zig` defines the synchronous `Provider` contract and owned results. `codec.zig` owns encoding, decoding, validation, and matching. `native.zig` implements profile-backed storage. Callers release returned names with `freeNames` and documents with `Document.deinit`.

Tool callbacks live in `src/tools/memory/memory.zig`; their specifications live in `src/builtins/tools.zig`. `DispatchContext.memory_provider` lets a host supply storage without changing the tool arguments or matching semantics. No libfx API or JavaScript host adapter is supplied here.

Writes pass through the ordinary tool permission gate. Reads, listing, and queries are read-only. Native storage rejects symlink and hardlink files and symlink storage directories. Generic `write_file` and `edit_file` calls cannot modify the active memory directory, including through path aliases; their error directs the model to `write_memory`. This guard does not claim to sandbox shell commands or other tools.

Focused runtime coverage lives in `tests/e2e/memory.test.ts`, classified as verification-only in the PGSO corpus. Inline tests cover the codec, native storage, permission gating, provider injection, and generic mutation boundary.
