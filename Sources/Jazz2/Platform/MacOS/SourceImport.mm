#include "SourceImport.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach-o/dyld.h>
#include <vector>

@interface Jazz2SourceChoice : NSObject
@property (nonatomic, strong) NSButton* folderButton;
@property (nonatomic, strong) NSButton* installerButton;
- (void)selectFolder:(id)sender;
- (void)selectInstaller:(id)sender;
@end

@implementation Jazz2SourceChoice
- (void)selectFolder:(id)sender
{
	self.folderButton.state = NSControlStateValueOn;
	self.installerButton.state = NSControlStateValueOff;
}

- (void)selectInstaller:(id)sender
{
	self.folderButton.state = NSControlStateValueOff;
	self.installerButton.state = NSControlStateValueOn;
}
@end

namespace Jazz2::Platform::MacOS
{
	namespace
	{
		void ShowError(NSString* message)
		{
			NSAlert* alert = [[NSAlert alloc] init];
			alert.alertStyle = NSAlertStyleWarning;
			alert.messageText = @"Import Failed";
			alert.informativeText = message;
			[alert addButtonWithTitle:@"OK"];
			[alert runModal];
		}

		bool IsGameFile(NSString* name)
		{
			static NSSet<NSString*>* extensions = [NSSet setWithArray:@[
				@"j2a", @"j2b", @"j2d", @"j2e", @"j2l", @"j2m", @"j2s", @"j2t", @"j2v",
				@"mod", @"s3m", @"xm", @"it", @"mo3", @"wav", @"ogg", @"mp3", @"mid", @"midi", @"anm"
			]];
			return [extensions containsObject:name.pathExtension.lowercaseString];
		}

		bool HasValidAnimations(NSString* directory)
		{
			NSFileManager* manager = [NSFileManager defaultManager];
			for (NSString* name in [manager contentsOfDirectoryAtPath:directory error:nil]) {
				NSString* lower = name.lowercaseString;
				if (![lower isEqualToString:@"anims.j2a"] && ![lower isEqualToString:@"animssw.j2a"]) continue;
				NSString* path = [directory stringByAppendingPathComponent:name];
				NSDictionary* attributes = [manager attributesOfItemAtPath:path error:nil];
				if (![attributes.fileType isEqualToString:NSFileTypeRegular] || [attributes fileSize] < 28) continue;
				NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:path];
				NSData* header = [handle readDataOfLength:16];
				[handle closeFile];
				if (header.length != 16) continue;
				const unsigned char* bytes = static_cast<const unsigned char*>(header.bytes);
				if (bytes[0] == 'A' && bytes[1] == 'L' && bytes[2] == 'I' && bytes[3] == 'B' &&
					bytes[4] == 0x00 && bytes[5] == 0xBA && bytes[6] == 0xBE && bytes[7] == 0x00 &&
					bytes[12] == 0x00 && bytes[13] == 0x02 && bytes[14] == 0x08 && bytes[15] == 0x18) return true;
			}
			return false;
		}

		NSString* FindGameDirectory(NSString* selected)
		{
			NSFileManager* manager = [NSFileManager defaultManager];
			NSMutableArray<NSDictionary*>* queue = [NSMutableArray arrayWithObject:@{ @"path": selected, @"depth": @0 }];
			for (NSUInteger index = 0; index < queue.count; ++index) {
				NSString* path = queue[index][@"path"];
				NSUInteger depth = [queue[index][@"depth"] unsignedIntegerValue];
				if (HasValidAnimations(path)) return path;
				if (depth >= 3) continue;
				for (NSString* name in [manager contentsOfDirectoryAtPath:path error:nil]) {
					if ([name hasPrefix:@"."]) continue;
					NSString* child = [path stringByAppendingPathComponent:name];
					NSDictionary* attributes = [manager attributesOfItemAtPath:child error:nil];
					if ([attributes.fileType isEqualToString:NSFileTypeDirectory]) {
						[queue addObject:@{ @"path": child, @"depth": @(depth + 1) }];
					}
				}
			}
			return nil;
		}

		bool ChooseImportSource(bool firstRun, bool& isInstaller)
		{
			NSAlert* introduction = [[NSAlert alloc] init];
			introduction.messageText = (firstRun ? @"Jazz Jackrabbit 2 Files Are Missing" : @"Import Jazz Jackrabbit 2 Files");
			introduction.informativeText = @"Choose how to provide the original game files. The game will copy the required files into its own Source folder.";
			NSView* choices = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 58)];
			Jazz2SourceChoice* choice = [[Jazz2SourceChoice alloc] init];
			NSButton* folderButton = [NSButton radioButtonWithTitle:@"Folder with extracted game files" target:choice action:@selector(selectFolder:)];
			folderButton.frame = NSMakeRect(0, 30, 380, 24);
			folderButton.state = NSControlStateValueOn;
			[choices addSubview:folderButton];
			NSButton* installerButton = [NSButton radioButtonWithTitle:@"GOG installer (.exe)" target:choice action:@selector(selectInstaller:)];
			installerButton.frame = NSMakeRect(0, 2, 380, 24);
			[choices addSubview:installerButton];
			choice.folderButton = folderButton;
			choice.installerButton = installerButton;
			introduction.accessoryView = choices;
			[introduction addButtonWithTitle:@"Continue"];
			[introduction addButtonWithTitle:(firstRun ? @"Quit" : @"Cancel")];
			NSModalResponse response = [introduction runModal];
			isInstaller = (choice.installerButton.state == NSControlStateValueOn);
			return response == NSAlertFirstButtonReturn;
		}

		bool ExtractInstaller(NSString* installerPath, NSString* outputDirectory)
		{
			uint32_t executablePathSize = 0;
			_NSGetExecutablePath(nullptr, &executablePathSize);
			std::vector<char> executablePath(executablePathSize);
			if (executablePath.empty() || _NSGetExecutablePath(executablePath.data(), &executablePathSize) != 0) {
				ShowError(@"Could not determine the location of the running game executable.");
				return false;
			}
			NSString* executable = [NSString stringWithUTF8String:executablePath.data()];
			if (!executable) {
				ShowError(@"Could not determine the location of the running game executable.");
				return false;
			}
			if (![executable isAbsolutePath]) {
				executable = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:executable];
			}
			executable = [executable stringByResolvingSymlinksInPath];
			NSString* contents = [[executable stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
			NSString* helper = [contents stringByAppendingPathComponent:@"Helpers/innoextract"];
			if (![[NSFileManager defaultManager] isExecutableFileAtPath:helper]) {
				ShowError([NSString stringWithFormat:@"The bundled innoextract helper is missing or cannot be executed at:\n%@", helper]);
				return false;
			}

			NSString* logPath = [outputDirectory stringByAppendingPathComponent:@"innoextract.log"];
			[[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
			NSFileHandle* log = [NSFileHandle fileHandleForWritingAtPath:logPath];
			if (!log) {
				ShowError(@"Could not create a temporary extraction log.");
				return false;
			}

			NSTask* task = [[NSTask alloc] init];
			task.executableURL = [NSURL fileURLWithPath:helper];
			task.currentDirectoryURL = [NSURL fileURLWithPath:[installerPath stringByDeletingLastPathComponent] isDirectory:YES];
			task.arguments = @[ @"--extract", @"--silent", @"--no-extract-unknown", @"--output-dir", outputDirectory, @"--", installerPath ];
			task.standardOutput = log;
			task.standardError = log;
			NSError* launchError = nil;
			if (![task launchAndReturnError:&launchError]) {
				[log closeFile];
				ShowError(launchError.localizedDescription);
				return false;
			}

			NSPanel* progress = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 90)
				styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
			progress.title = @"Extracting GOG Installer";
			NSTextField* message = [NSTextField labelWithString:@"Extracting game files. This may take a few minutes."];
			message.frame = NSMakeRect(20, 53, 340, 20);
			[progress.contentView addSubview:message];
			NSProgressIndicator* spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(174, 13, 32, 32)];
			spinner.style = NSProgressIndicatorStyleSpinning;
			[progress.contentView addSubview:spinner];
			[progress center];
			[progress makeKeyAndOrderFront:nil];
			[spinner startAnimation:nil];
			while (task.isRunning) {
				@autoreleasepool {
					[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
				}
			}
			[task waitUntilExit];
			[spinner stopAnimation:nil];
			[progress orderOut:nil];
			[log closeFile];

			if (task.terminationStatus != 0) {
				NSString* details = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
				details = [details stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				if (details.length > 1200) details = [details substringFromIndex:details.length - 1200];
				ShowError([NSString stringWithFormat:@"The installer could not be extracted (exit code %d).%@%@", task.terminationStatus,
					(details.length ? @"\n\n" : @""), (details ?: @"")]);
				return false;
			}
			return true;
		}
	}

	SourceImportResult ImportSourceDirectory(const char* sourcePath, const char* cachePath, bool firstRun)
	{
		@autoreleasepool {
			NSFileManager* manager = [NSFileManager defaultManager];
			NSString* destination = [NSString stringWithUTF8String:sourcePath];
			NSString* cache = [NSString stringWithUTF8String:cachePath];
			if (!destination || !cache) return SourceImportResult::Failed;

			bool isInstaller = false;
			if (!ChooseImportSource(firstRun, isInstaller)) return SourceImportResult::Cancelled;

			NSOpenPanel* panel = [NSOpenPanel openPanel];
			panel.canChooseDirectories = !isInstaller;
			panel.canChooseFiles = isInstaller;
			panel.allowsMultipleSelection = NO;
			panel.prompt = (isInstaller ? @"Choose Installer" : @"Choose Folder");
			panel.message = (isInstaller ? @"Select the GOG installer (.exe) for Jazz Jackrabbit 2." : @"Select the folder containing the extracted Jazz Jackrabbit 2 game files.");
			if (isInstaller) {
				UTType* exeType = [UTType typeWithFilenameExtension:@"exe"];
				if (exeType) panel.allowedContentTypes = @[ exeType ];
			}
			if ([panel runModal] != NSModalResponseOK) return SourceImportResult::Cancelled;

			NSString* temporaryDirectory = nil;
			NSString* selectedPath = panel.URL.path;
			if (isInstaller) {
				if (![selectedPath.pathExtension.lowercaseString isEqualToString:@"exe"]) {
					ShowError(@"Select a GOG installer with an .exe extension.");
					return SourceImportResult::Failed;
				}
				temporaryDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"jazz2-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
				NSError* temporaryError = nil;
				if (![manager createDirectoryAtPath:temporaryDirectory withIntermediateDirectories:NO
					attributes:@{ NSFilePosixPermissions: @0700 } error:&temporaryError]) {
					ShowError(temporaryError.localizedDescription);
					return SourceImportResult::Failed;
				}
				if (!ExtractInstaller(selectedPath, temporaryDirectory)) {
					[manager removeItemAtPath:temporaryDirectory error:nil];
					return SourceImportResult::Failed;
				}
			}

			@try {
			NSString* gameDirectory = FindGameDirectory(isInstaller ? temporaryDirectory : selectedPath);
			if (!gameDirectory) {
				ShowError(@"No valid Anims.j2a or AnimsSw.j2a file was found in this folder. Choose the folder containing the extracted original game files.");
				return SourceImportResult::Failed;
			}
			if ([gameDirectory.stringByStandardizingPath isEqualToString:destination.stringByStandardizingPath]) {
				ShowError(@"The selected folder is already the game's Source folder.");
				return SourceImportResult::Failed;
			}

			NSMutableArray<NSDictionary*>* files = [NSMutableArray array];
		NSMutableDictionary<NSString*, NSString*>* existing = [NSMutableDictionary dictionary];
		for (NSString* name in [manager contentsOfDirectoryAtPath:destination error:nil]) {
			NSString* path = [destination stringByAppendingPathComponent:name];
			NSDictionary* attributes = [manager attributesOfItemAtPath:path error:nil];
			if ([attributes.fileType isEqualToString:NSFileTypeRegular]) existing[name.lowercaseString] = name;
		}
		NSUInteger replacements = 0;
		NSMutableSet<NSString*>* seenNames = [NSMutableSet set];
		for (NSString* name in [manager contentsOfDirectoryAtPath:gameDirectory error:nil]) {
			if (!IsGameFile(name)) continue;
			NSString* path = [gameDirectory stringByAppendingPathComponent:name];
			NSDictionary* attributes = [manager attributesOfItemAtPath:path error:nil];
			if (![attributes.fileType isEqualToString:NSFileTypeRegular]) continue;
			if ([seenNames containsObject:name.lowercaseString]) {
				ShowError(@"Two files in the selected folder differ only by letter case. They cannot be imported safely together.");
				return SourceImportResult::Failed;
			}
			[seenNames addObject:name.lowercaseString];
			NSString* targetName = existing[name.lowercaseString] ?: name;
			NSString* target = [destination stringByAppendingPathComponent:targetName];
			if ([manager fileExistsAtPath:target] && !existing[name.lowercaseString]) {
				ShowError(@"A game file has the same name as an existing folder in Source.");
				return SourceImportResult::Failed;
			}
				if (existing[name.lowercaseString]) ++replacements;
				[files addObject:@{ @"source": path, @"name": targetName }];
			}
			if (files.count == 0) {
				ShowError(@"No supported game files were found.");
				return SourceImportResult::Failed;
			}
			if (replacements > 0) {
				NSAlert* confirmation = [[NSAlert alloc] init];
				confirmation.alertStyle = NSAlertStyleWarning;
				confirmation.messageText = @"Replace Existing Source Files?";
				confirmation.informativeText = [NSString stringWithFormat:@"%lu files will be copied; %lu existing files in Source will be replaced. Jazz2.config and Jazz2.resume will be kept.", (unsigned long)files.count, (unsigned long)replacements];
				[confirmation addButtonWithTitle:@"Replace"];
				[confirmation addButtonWithTitle:@"Cancel"];
				if ([confirmation runModal] != NSAlertFirstButtonReturn) return SourceImportResult::Cancelled;
			}

			NSError* error = nil;
			if (![manager createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:&error]) {
				ShowError(error.localizedDescription);
				return SourceImportResult::Failed;
			}
		// Keep staging beside Source so replacing and restoring files stays on the same volume.
		NSString* staging = [[destination stringByDeletingLastPathComponent]
			stringByAppendingPathComponent:[@".jazz2-import-" stringByAppendingString:[[NSUUID UUID] UUIDString]]];
			if (![manager createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:&error]) {
				ShowError(error.localizedDescription);
				return SourceImportResult::Failed;
			}
			NSString* stagedFiles = [staging stringByAppendingPathComponent:@"new"];
			NSString* backups = [staging stringByAppendingPathComponent:@"backup"];
			[manager createDirectoryAtPath:stagedFiles withIntermediateDirectories:YES attributes:nil error:nil];
			[manager createDirectoryAtPath:backups withIntermediateDirectories:YES attributes:nil error:nil];

			for (NSDictionary* item in files) {
				if (![manager copyItemAtPath:item[@"source"] toPath:[stagedFiles stringByAppendingPathComponent:item[@"name"]] error:&error]) break;
			}
			NSMutableArray<NSDictionary*>* completed = [NSMutableArray array];
		if (!error) {
			for (NSDictionary* item in files) {
					NSString* name = item[@"name"];
					NSString* target = [destination stringByAppendingPathComponent:name];
					NSString* backup = [backups stringByAppendingPathComponent:name];
					BOOL hadExisting = [manager fileExistsAtPath:target];
					if (hadExisting && ![manager moveItemAtPath:target toPath:backup error:&error]) break;
					[completed addObject:@{ @"target": target, @"backup": backup, @"existing": @(hadExisting) }];
				if (![manager moveItemAtPath:[stagedFiles stringByAppendingPathComponent:name] toPath:target error:&error]) break;
			}
		}
		if (!error) {
			// Source.idx is the existing cache validity marker. Removing it makes
			// RefreshCache() rebuild Source.pak and the converted levels.
			NSString* cacheIndex = [cache stringByAppendingPathComponent:@"Source.idx"];
			if ([manager fileExistsAtPath:cacheIndex]) [manager removeItemAtPath:cacheIndex error:&error];
		}
		if (error) {
			BOOL restored = YES;
			for (NSDictionary* item in [completed reverseObjectEnumerator]) {
				if ([manager fileExistsAtPath:item[@"target"]] && ![manager removeItemAtPath:item[@"target"] error:nil]) restored = NO;
				if ([item[@"existing"] boolValue] && ![manager moveItemAtPath:item[@"backup"] toPath:item[@"target"] error:nil]) restored = NO;
			}
			if (!restored) {
				ShowError([NSString stringWithFormat:@"%@\n\nIf needed, restore the previous files from: %@", error.localizedDescription, backups]);
				return SourceImportResult::Failed;
			}
			ShowError(error.localizedDescription);
		}
		[manager removeItemAtPath:staging error:nil];
		if (error) return SourceImportResult::Failed;
			if (!firstRun) {
				NSAlert* success = [[NSAlert alloc] init];
				success.messageText = @"Game Files Imported";
				success.informativeText = @"The game will now quit. Restart it to rebuild the cache.";
				[success addButtonWithTitle:@"OK"];
				[success runModal];
			}
			return SourceImportResult::Imported;
			} @finally {
				if (temporaryDirectory) [manager removeItemAtPath:temporaryDirectory error:nil];
			}
		}
	}
}
