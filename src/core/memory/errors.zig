/// Stable explanations for validation/storage errors. Unknown OS/provider
/// errors keep their symbolic name rather than being silently generalized.
pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidMemoryFilename => "Memory filename must be a safe single filename with an optional .md suffix.",
        error.InvalidFrontmatter => "Frontmatter must be a flat YAML mapping containing scalars or scalar arrays.",
        error.AlreadyHasFrontmatter => "Content already has frontmatter; pass metadata separately.",
        error.InvalidMemoryQuery => "Memory query must map keys to scalar values; null means key existence.",
        error.MemoryDocumentTooLarge => "Memory document exceeds the 8 MiB storage limit.",
        error.UnsafeMemoryFile, error.DurablePathUnsafe, error.SymLinkLoop => "Memory storage refuses symbolic links, hard links, and non-regular files.",
        error.FileNotFound => "Memory document was not found.",
        error.MemoryHomeUnavailable => "Memory storage requires an absolute HOME or configured FX_HOME.",
        error.AccessDenied, error.PermissionDenied => "Memory storage access was denied.",
        error.DurableReplacePostRenameFailed => "Memory was replaced, but durable storage could not be confirmed. Read before retrying.",
        error.DurableReplacePreRenameFailed => "Memory could not be saved; the previous document was not replaced.",
        else => @errorName(err),
    };
}
