//
//  main.m
//  marzipanify
//
//  Created by Steven Troughton-Smith on 16/06/2018.
//  Copyright © 2018 Steven Troughton-Smith. All rights reserved.
//

#define PLATFORM_IOSMAC 6

@import Foundation;
@import ObjectiveC.runtime;
@import MachO;
@import vmnet;

@implementation NSData (LoadCommand)
- (uint32_t)loadCommand {
    struct load_command *cmd = (struct load_command*)self.bytes;
    return cmd->cmd;
}

- (NSString*)loadCommandDylibName {
    struct dylib_command *cmd = (struct dylib_command*)self.bytes;
    NSUInteger offset = cmd->dylib.name.offset;
    NSUInteger maxSize = self.length - offset;
    char *name = calloc(maxSize + 1, 1);
    memcpy(name, self.bytes + offset, maxSize);
    NSString *string = [NSString stringWithUTF8String:name];
    free(name);
    return string;
}

@end

#define DEBUG_PRINT_COMMANDLINE 0
#define PRINT_LIBSWIFT_LINKER_ERRORS 0
BOOL INJECT_MARZIPAN_GLUE = NO;
BOOL DRY_RUN = NO;

void processEmbeddedBundle(NSString *bundlePath);
void processEmbeddedLibrary(NSString *libraryPath);

NSArray *__whitelistedMacFrameworks = nil;

NSString *injectedCode = @"#import <Foundation/Foundation.h>\n\
#import <objc/runtime.h>\n\
#import <dlfcn.h>\n\
int dyld_get_active_platform();\n\
\n\
int my_dyld_get_active_platform()\n\
{\n\
	return 6;\n\
}\n\
\n\
typedef struct interpose_s { void *new_func; void *orig_func; } interpose_t;\n\
\n\
static const interpose_t interposing_functions[] __attribute__ ((used, section(\\\"__DATA, __interpose\\\"))) = {\n\
	{ (void *)my_dyld_get_active_platform, (void *)dyld_get_active_platform }\n\
};\n\
@implementation NSBundle (Marzipan)\n\
+(NSString *)currentStringsTableName { return nil; }\n\
@end\n\
@implementation NSObject (Marzipan)\n\
-(CGFloat)_bodyLeading { return 0.0; }\n\
@end";

//int my_dlopen(char *path, int flags)\n\
//{\n\
//char *newPath = malloc(1024*8);\n\
//memset(newPath, 0, 1024*8);\n\
//FILE *file;\n\
//if (!(file = fopen(path, \\\"r\\\")))\n\
//{\n\
//	strcat(newPath,\\\"/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/Library/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot\\\");\n\
//	strcat(newPath, path);\n\
//	printf(newPath);\n\
//	return dlopen(newPath, flags);\n\
//}\n\
//return dlopen(path, flags);\n\
//}\n\
				   
				   
//@implementation NSObject\n\
//-(void)swizzled_updateControlsForLargeNumberKeysInTracker:(id)a layout:(id)b isVertical:(id)c {}\n\
//@end\n\
//__attribute__((constructor)) void marzipanEntryPoint()\n\
//{\n\
//	static dispatch_once_t onceToken;\n\
//	dispatch_once(&onceToken, ^{\n\
//		Class class = NSClassFromString(@\\\"CalcController\\\");\n\
//		\n\
//		SEL defaultSelector = NSSelectorFromString(@\\\"updateControlsForLargeNumberKeysInTracker:layout:isVertical:\\\");\n\
//		SEL swizzledSelector = NSSelectorFromString(@\\\"swizzled_updateControlsForLargeNumberKeysInTracker:layout:isVertical:\\\");\n\
//		\n\
//		Method defaultMethod = class_getInstanceMethod(class, defaultSelector);\n\
//		Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);\n\
//		\n\
//		BOOL isMethodExists = !class_addMethod(class, defaultSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod));\n\
//		\n\
//		if (isMethodExists) {\n\
//			method_exchangeImplementations(defaultMethod, swizzledMethod);\n\
//		}\n\
//		else {\n\
//			class_replaceMethod(class, swizzledSelector, method_getImplementation(defaultMethod), method_getTypeEncoding(defaultMethod));\n\
//		}\n\
//	});\n\
//}";

void printSectionDivider(NSString *title)
{
	NSUInteger len = title.length;
	NSUInteger spaces = MIN(40,((80-len)/2));

	printf("\n");

	for (int i = 0; i < spaces; i++)
		printf("-");
	
	printf("%s", title.UTF8String);
	
	for (int i = 0; i < spaces; i++)
		printf("-");
	
	printf("\n");
}

NSString *binaryPathForBundlePath(NSString *bundlePath)
{
	NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
	NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
	NSString *executableName = infoPlist[@"CFBundleExecutable"];
	NSString *executablePath = [bundlePath stringByAppendingPathComponent:executableName];
	
	return executablePath;
}

void processInfoPlist(NSString *infoPlistPath)
{
	NSMutableDictionary *infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:infoPlistPath];
	infoPlist[@"LSRequiresIPhoneOS"] = @NO;
	infoPlist[@"CFBundleSupportedPlatforms"] = @[@"MacOSX"];
	infoPlist[@"MinimumOSVersion"] = @"10.14";
	infoPlist[@"CanInheritApplicationStateFromOtherProcesses"] = @YES;
	infoPlist[@"UIUserInterfaceStyle"] = @"Automatic";

	[infoPlist removeObjectForKey:@"DTSDKName"];
	[infoPlist removeObjectForKey:@"DTSDKBuild"];
	[infoPlist removeObjectForKey:@"DTCompiler"];
	[infoPlist removeObjectForKey:@"DTPlatformBuild"];
	[infoPlist removeObjectForKey:@"DTPlatformVersion"];
	[infoPlist removeObjectForKey:@"DTXcode"];
	[infoPlist removeObjectForKey:@"DTXcodeBuild"];
	[infoPlist removeObjectForKey:@"DTPlatformName"];
	
	if (INJECT_MARZIPAN_GLUE)
	{
		infoPlist[@"LSEnvironment"] = @{ @"DYLD_INSERT_LIBRARIES" : @"@executable_path/../Frameworks/MarzipanGlue.dylib" };
	}
	
	[infoPlist writeToFile:infoPlistPath atomically:NO];
}

void injectMarzipanGlue(NSString *bundlePath)
{
	printf("WARNING: Injecting Marzipan patch code into this app bundle.\n");
	
	NSString *frameworksPath = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
	
	[[NSFileManager defaultManager] createDirectoryAtPath:frameworksPath withIntermediateDirectories:YES attributes:nil error:nil];
	
	NSString *compilationCommand = [NSString stringWithFormat:@"echo \"%@\" | xcrun clang -x objective-c -mmacosx-version-min=10.14 - -dynamiclib -framework Foundation -o \"%@/MarzipanGlue.dylib\"", injectedCode, frameworksPath];
	
#if DEBUG_PRINT_COMMANDLINE
	printf("%s\n", compilationCommand.UTF8String);
#endif
	
	if (!DRY_RUN)
		system(compilationCommand.UTF8String);
}

BOOL repackageAppBundle(NSString *bundlePath)
{
	if (DRY_RUN)
		return NO;
	
	NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
	NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
	NSString *executableName = infoPlist[@"CFBundleExecutable"];
	
	NSString *macOSPath = [bundlePath stringByAppendingPathComponent:@"Contents/MacOS"];
	NSString *resourcesPath = [bundlePath stringByAppendingPathComponent:@"Contents/Resources"];
	NSString *contentsPath = [bundlePath stringByAppendingPathComponent:@"Contents/"];
	
	processInfoPlist(infoPlistPath);
	
	[[NSFileManager defaultManager] createDirectoryAtPath:macOSPath withIntermediateDirectories:YES attributes:nil error:nil];
	[[NSFileManager defaultManager] createDirectoryAtPath:resourcesPath withIntermediateDirectories:YES attributes:nil error:nil];
	
	NSArray *bundleContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
	
	for (NSString *item in bundleContents)
	{
		NSString *itemPath = [bundlePath stringByAppendingPathComponent:item];
		
		if ([item isEqualToString:executableName])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[macOSPath stringByAppendingPathComponent:item] error:nil];
		}
		else if ([item isEqualToString:@"Info.plist"])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[contentsPath stringByAppendingPathComponent:item] error:nil];
		}
		else if ([item isEqualToString:@"PkgInfo"])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[contentsPath stringByAppendingPathComponent:item] error:nil];
		}
		else if ([item isEqualToString:@"Frameworks"])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[contentsPath stringByAppendingPathComponent:item] error:nil];
		}
		else if ([item isEqualToString:@"PlugIns"])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[contentsPath stringByAppendingPathComponent:item] error:nil];
		}
		else if ([item isEqualToString:@"_CodeSignature"])
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[contentsPath stringByAppendingPathComponent:item] error:nil];
		}
		else
		{
			[[NSFileManager defaultManager] moveItemAtPath:itemPath toPath:[resourcesPath stringByAppendingPathComponent:item] error:nil];
		}
	}
	
	return YES;
}

NSArray *modifyMachHeaderAndReturnNSArrayOfLoadedDylibs(NSString *binaryPath)
{
	NSMutableArray *dylibs = @[].mutableCopy;
	NSDictionary *attribs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:binaryPath error:nil];
	
	long sz = [attribs[@"NSFileSystemSize"] longValue];
	
	int handle = open(binaryPath.UTF8String, DRY_RUN ? O_RDONLY : O_RDWR, 0);
	char *macho = mmap(NULL, sz, DRY_RUN ? PROT_READ : (PROT_READ|PROT_WRITE), MAP_SHARED, handle, 0);
	
	if (handle == -1)
	{
		printf("ERROR: can't load %s\n", binaryPath.UTF8String);
		close(handle);
		return @[];
	}
	
	uint8_t *imageHeaderPtr = (uint8_t*)macho;
	typedef struct load_command load_command;
    struct mach_header_64 *header64 = (struct mach_header_64 *)imageHeaderPtr;
	
    if (header64->magic != MH_MAGIC_64) {
        printf("Invalid magic, try thinning the binary\n");
        exit(-1);
    }
    
    if (header64->cputype == CPU_TYPE_ARM64) {
        printf("Changing architecture\n");
        if (!DRY_RUN) {
            header64->cputype = CPU_TYPE_X86_64;
            uint32_t subtype_features = header64->cpusubtype & CPU_SUBTYPE_MASK;
            header64->cpusubtype = subtype_features | CPU_SUBTYPE_X86_64_ALL;
            // remove PIE
            header64->flags &= ~MH_PIE;
            // mark emulatable
            header64->reserved = 0x456D400C;
        }
    } else {
        printf("Not an arm64 binary (0x%x)\n", header64->cputype);
        exit(-1);
    }
    
	imageHeaderPtr += sizeof(struct mach_header_64);
    
    // read all load commands
    NSMutableArray *loadCommands = [NSMutableArray new];
	for(int i = 0; i < header64->ncmds > 0; ++i)
	{
        load_command *command = (load_command*)(imageHeaderPtr);
        NSMutableData *commandData = [NSMutableData dataWithBytes:command length:command->cmdsize];
        [loadCommands addObject:commandData];
        imageHeaderPtr += command->cmdsize;
    }
    
    // find dylibs
    for (NSMutableData *commandData in loadCommands)
    {
        if ([commandData loadCommand] == LC_LOAD_DYLIB || [commandData loadCommand] == LC_LOAD_WEAK_DYLIB)
		{
            NSString *dylibName = [commandData loadCommandDylibName];
			printf("LC_LOAD_DYLIB “%s”\n", dylibName.UTF8String);
			[dylibs addObject:dylibName];
		}
	}
    
    // replace LC_VERSION_MIN_IPHONEOS with LC_BUILD_VERSION, or update LC_BUILD_VERSION
    NSUInteger buildVersionIndex = [loadCommands indexOfObjectPassingTest:^BOOL(NSData * _Nonnull lc, NSUInteger idx, BOOL * _Nonnull stop) {
        return lc.loadCommand == LC_BUILD_VERSION;
    }];
    NSMutableData *buildVersionData = [NSMutableData dataWithLength:sizeof(struct build_version_command) + sizeof(struct build_tool_version)];
    struct build_version_command *buildVersionCmd = (struct build_version_command*)buildVersionData.mutableBytes;
    buildVersionCmd->cmd = LC_BUILD_VERSION;
    buildVersionCmd->cmdsize = (uint32_t)buildVersionData.length;
    buildVersionCmd->platform = PLATFORM_IOSMAC;
    buildVersionCmd->minos = 12<<16|0<<8|0;
    buildVersionCmd->sdk = 10<<16|14<<8|0;
    buildVersionCmd->ntools = 1;
    struct build_tool_version *buildVersionTool = (struct build_tool_version*)(buildVersionData.mutableBytes + sizeof(struct build_version_command));
    buildVersionTool[0].tool = TOOL_LD;
    buildVersionTool[0].version = 0x2000100;
    if (buildVersionIndex == NSNotFound) {
        buildVersionIndex = [loadCommands indexOfObjectPassingTest:^BOOL(NSData * _Nonnull lc, NSUInteger idx, BOOL * _Nonnull stop) {
            return lc.loadCommand == LC_VERSION_MIN_IPHONEOS;
        }];
        if (buildVersionIndex == NSNotFound) {
            printf("No LC_BUILD_VERSION or LC_VERSION_MIN_IPHONEOS, what do?\n");
            exit(-1);
        }
        printf("Replacing LC_VERSION_MIN_IPHONEOS with LC_BUILD_VERSION\n");
    }
    if (!DRY_RUN) {
        [loadCommands replaceObjectAtIndex:buildVersionIndex withObject:buildVersionData];
    }
    
    // write new load commands
    NSMutableData *allLoadCommands = [NSMutableData dataWithCapacity:header64->sizeofcmds];
    for (NSData *loadCommand in loadCommands) {
        [allLoadCommands appendData:loadCommand];
    }
    if (!DRY_RUN) {
        header64->ncmds = (uint32_t)loadCommands.count;
        header64->sizeofcmds = (uint32_t)allLoadCommands.length;
        // TODO: check that there's space available
        memcpy(macho+sizeof(struct mach_header_64), allLoadCommands.bytes, allLoadCommands.length);
    }
	msync(macho, sz, MS_SYNC);
	
	munmap(macho, sz);
	close(handle);
	
	return [NSArray arrayWithArray:dylibs];
}

NSString *newLinkerPathForLoadedDylib(NSString *loadedDylib)
{
	if ([loadedDylib hasPrefix:@"/System/iOSSupport"])
		return loadedDylib;
	
	NSString *possibleiOSMacDylibPath = [@"/System/iOSSupport" stringByAppendingPathComponent:loadedDylib];
	//NSString *possibleSimulatorDylibPath = [@"/System/iOSSimulator" stringByAppendingPathComponent:loadedDylib];

	if ([[NSFileManager defaultManager] fileExistsAtPath:possibleiOSMacDylibPath])
	{
		return possibleiOSMacDylibPath;
	}
	
	if (![[NSFileManager defaultManager] fileExistsAtPath:loadedDylib] && ![loadedDylib hasPrefix:@"@rpath"] && ![loadedDylib hasPrefix:@"@executable_path"])
	{
		printf("WARNING: no linker redirect available for %s\n", loadedDylib.UTF8String);
	}
	
	return loadedDylib;
}

void dumpEntitlementsForBinary(NSString *appBundlePath, NSString *appBinaryPath)
{
	NSString *entitlementCommand = [NSString stringWithFormat:@"codesign -d --entitlements :- \"%@\" > \"Entitlements-%@.plist\" &> /dev/null", appBundlePath, appBinaryPath.lastPathComponent];
	
#if DEBUG_PRINT_COMMANDLINE
	printf("%s\n", entitlementCommand.UTF8String);
#endif
	if (!DRY_RUN)
		system(entitlementCommand.UTF8String);
}

void resignBinary(NSString *appBundlePath, NSString *appBinaryPath)
{
	NSString *entitlementsPath = [NSString stringWithFormat:@"Entitlements-%@.plist", appBinaryPath.lastPathComponent];
	
	NSMutableDictionary *entitlementsDict = [NSMutableDictionary dictionaryWithContentsOfFile:entitlementsPath];
	
	if (!entitlementsDict)
		entitlementsDict = @{}.mutableCopy;
	
	entitlementsDict[@"com.apple.private.iosmac"] = @YES;
	[entitlementsDict writeToFile:entitlementsPath atomically:NO];
	
	NSString *resignCommand = [NSString stringWithFormat:@"/usr/bin/codesign --force --sign - --entitlements \"%@\" --timestamp=none \"%@\" &> /dev/null", entitlementsPath, appBundlePath];
#if DEBUG_PRINT_COMMANDLINE
	printf("%s\n", resignCommand.UTF8String);
#endif
	if (!DRY_RUN)
		system(resignCommand.UTF8String);
}

void processEmbeddedBundle(NSString *bundlePath)
{
	printSectionDivider(bundlePath.lastPathComponent);

	NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
	NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
	NSString *executableName = infoPlist[@"CFBundleExecutable"];
	
	NSString *frameworkBinaryPath = [bundlePath stringByAppendingPathComponent:executableName];
	NSArray *embeddedBundlesPaths = @[[bundlePath stringByAppendingPathComponent:@"Frameworks"], [bundlePath stringByAppendingPathComponent:@"PlugIns"]];
	
	for (NSString *embeddedBundlesPath in embeddedBundlesPaths)
	{
		NSArray *embeddedBundles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:embeddedBundlesPath error:nil];
		
		if (embeddedBundles)
		{
			for (NSString *framework in embeddedBundles)
			{
				NSString *targetBundlePath = [embeddedBundlesPath stringByAppendingPathComponent:framework];
				BOOL isBundle = NO;
				
				[[NSFileManager defaultManager] fileExistsAtPath:targetBundlePath isDirectory:&isBundle];
				
				if (isBundle)
				{
					processEmbeddedBundle([embeddedBundlesPath stringByAppendingPathComponent:framework]);
				}
				else
				{
					processEmbeddedLibrary([embeddedBundlesPath stringByAppendingPathComponent:framework]);
				}
			}
		}
	}
	
	dumpEntitlementsForBinary(bundlePath, frameworkBinaryPath);
	
	/* Do Linker Redirects */
	
	NSArray *dylibs = modifyMachHeaderAndReturnNSArrayOfLoadedDylibs(frameworkBinaryPath);
	
	for (NSString *dylib in dylibs)
	{
		NSString *redirectedDylib = newLinkerPathForLoadedDylib(dylib);
		
		if (![dylib isEqualToString:redirectedDylib])
		{
			
			NSString *install_name_tool_command = [NSString stringWithFormat:@"install_name_tool -change \"%@\" \"%@\" \"%@\"", dylib, redirectedDylib, frameworkBinaryPath];
			
#if DEBUG_PRINT_COMMANDLINE
			printf("%s\n", install_name_tool_command.UTF8String);
#endif
			if (!DRY_RUN)
				system([install_name_tool_command UTF8String]);
		}
	}
	
	resignBinary(bundlePath, frameworkBinaryPath);
}

void processEmbeddedLibrary(NSString *libraryPath)
{
#if !PRINT_LIBSWIFT_LINKER_ERRORS
	if (![libraryPath.lastPathComponent hasPrefix:@"libswift"])
#endif
		printSectionDivider(libraryPath.lastPathComponent);
	
	NSString *frameworkBinaryPath = libraryPath;
	
	dumpEntitlementsForBinary(frameworkBinaryPath, frameworkBinaryPath);
	
	/* Do Linker Redirects */
	
	NSArray *dylibs = modifyMachHeaderAndReturnNSArrayOfLoadedDylibs(frameworkBinaryPath);
	
	for (NSString *dylib in dylibs)
	{
		NSString *redirectedDylib = newLinkerPathForLoadedDylib(dylib);
		
		if (![dylib isEqualToString:redirectedDylib])
		{
			
			NSString *install_name_tool_command = [NSString stringWithFormat:@"install_name_tool -change \"%@\" \"%@\" \"%@\"", dylib, redirectedDylib, frameworkBinaryPath];
			
#if DEBUG_PRINT_COMMANDLINE
			printf("%s\n", install_name_tool_command.UTF8String);
#endif
			if (!DRY_RUN)
				system([install_name_tool_command UTF8String]);
		}
	}
	
	resignBinary(frameworkBinaryPath, frameworkBinaryPath);
}

void loadWhitelist()
{
	__whitelistedMacFrameworks = [[NSString stringWithContentsOfFile:@"/System/iOSSupport/dyld/macOS-whitelist.txt" usedEncoding:nil error:nil] componentsSeparatedByString:@"\n"];
}

void setupEnvironmentVariables()
{
	char *injectEnv = getenv("INJECT_MARZIPAN_GLUE");
	char *dryRunEnv = getenv("DRY_RUN");

	if (injectEnv)
	{
		INJECT_MARZIPAN_GLUE = (injectEnv[0] == '1');
	}
	
	if (dryRunEnv)
	{
		DRY_RUN = (dryRunEnv[0] == '1');
	}
}

void print_usage()
{
	printf("usage: marzipanify MyApp.app\n\n");
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		
		if (argc < 2)
		{
			print_usage();
			return -1;
		}
		
		NSString *appBundlePath = [NSString stringWithUTF8String:argv[1]];
		NSString *appBinaryPath = binaryPathForBundlePath(appBundlePath);
		NSArray *embeddedFrameworksPaths = @[[appBundlePath stringByAppendingPathComponent:@"Frameworks"], [appBundlePath stringByAppendingPathComponent:@"PlugIns"]];
		
		setupEnvironmentVariables();
		
		BOOL treatAsBinaryFile = NO;
		
		loadWhitelist();
		
		if ([appBundlePath hasSuffix:@".framework"] || [appBundlePath hasSuffix:@".bundle"])
		{
			processEmbeddedBundle(appBundlePath);
			return 0;
		}
		
		if (![appBundlePath hasSuffix:@".app"])
		{
			if (![[NSFileManager defaultManager] fileExistsAtPath:appBundlePath isDirectory:nil])
			{
				print_usage();
				return -1;
			}
			else
			{
				/* Treat as a single binary file; attempt to change the mach header and ignore linker or bundle packaging */
				treatAsBinaryFile = YES;
			}
		}
		
		printSectionDivider(appBundlePath.lastPathComponent);
		
		/* Dump Entitlements */
		
		dumpEntitlementsForBinary(appBundlePath, appBinaryPath);
		
		if (INJECT_MARZIPAN_GLUE)
		{
			/* Inject some glue code */
			injectMarzipanGlue(appBundlePath);
		}
		
		/* Do Linker Redirects */
		
		NSArray *dylibs = modifyMachHeaderAndReturnNSArrayOfLoadedDylibs(appBinaryPath);
		
		for (NSString *dylib in dylibs)
		{
			NSString *redirectedDylib = newLinkerPathForLoadedDylib(dylib);
			
			if (![dylib isEqualToString:redirectedDylib])
			{
				
				NSString *install_name_tool_command = [NSString stringWithFormat:@"install_name_tool -change \"%@\" \"%@\" \"%@\"", dylib, redirectedDylib, appBinaryPath];
				
#if DEBUG_PRINT_COMMANDLINE
				printf("%s\n", install_name_tool_command.UTF8String);
#endif
				if (!DRY_RUN)
					system([install_name_tool_command UTF8String]);
			}
		}
		
		/* Add @rpath */
		
		NSString *rpathCommand = [NSString stringWithFormat:@"install_name_tool -add_rpath \"@executable_path/../Frameworks/\" \"%@\"", appBinaryPath];
		
#if DEBUG_PRINT_COMMANDLINE
		printf("%s\n", rpathCommand.UTF8String);
#endif
		if (!DRY_RUN)
			system(rpathCommand.UTF8String);
		
		if (!treatAsBinaryFile)
		{
			/* Process Frameworks */
			
			for (NSString *embeddedFrameworksPath in embeddedFrameworksPaths)
			{
				NSArray *embeddedFrameworks = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:embeddedFrameworksPath error:nil];
				
				for (NSString *framework in embeddedFrameworks)
				{
					NSString *targetBundlePath = [embeddedFrameworksPath stringByAppendingPathComponent:framework];
					BOOL isBundle = NO;
					
					[[NSFileManager defaultManager] fileExistsAtPath:targetBundlePath isDirectory:&isBundle];
					
					if (isBundle)
					{
						processEmbeddedBundle([embeddedFrameworksPath stringByAppendingPathComponent:framework]);
					}
					else
					{
						processEmbeddedLibrary([embeddedFrameworksPath stringByAppendingPathComponent:framework]);
					}
				}
			}
			
			/* Package App */
			
			repackageAppBundle(appBundlePath);
		}

		/* Re-sign */
		
		resignBinary(appBundlePath, appBinaryPath);
	}
	return 0;
}
