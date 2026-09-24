#pragma once

namespace Jazz2::Platform::MacOS
{
	enum class SourceImportResult {
		Cancelled,
		Imported,
		Failed
	};

	// Call from the main thread. The selected directory is never modified.
	SourceImportResult ImportSourceDirectory(const char* sourcePath, const char* cachePath, bool firstRun);
}
