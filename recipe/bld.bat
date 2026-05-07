@echo on
setlocal

REM ============================================================================
REM Stage build helpers and pre-generated MSBuild config.
REM ============================================================================

set "PATH=%SRC_DIR%\build_helpers;%PATH%"

REM Note: previous attempts used a `msbuild.cmd` shim that forwarded to
REM `dotnet msbuild`. That worked for SDK resolution but broke vcxproj C++
REM compilation -- VS's C++ tasks (Microsoft.Build.CPPTasks) target .NET
REM Framework and use Microsoft.Build.Utilities.CanonicalTrackedOutputFiles,
REM which dotnet msbuild's .NET Core MSBuild doesn't expose.
REM Fall back to VS BuildTools' msbuild.exe (full-framework). SDK resolution
REM is then handled via MSBuildSDKsPath + inline-pinned Sdk references.

set "WixSkipVsDevCmd=1"
set "DOTNET_ROOT=%BUILD_PREFIX%\dotnet"
set "MSBuildSDKsPath=%BUILD_PREFIX%\dotnet\sdk\8.0.100\Sdks"

REM Disable .NET workload manifest resolution. Microsoft.NET.Sdk.ImportWorkloads.props
REM imports the special "Microsoft.NET.SDK.WorkloadAutoImportPropsLocator" SDK,
REM which probes dotnet's sdk-manifests directory. We don't target any .NET
REM workload (mobile, browser, etc.) so this is purely a stumbling block.
set "MSBuildEnableWorkloadResolver=false"

REM Locate VS 2022 install (BuildTools requires `-products *`).
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -products * -version [17.0^,18.0^) -property installationPath`) do set "_VS_INSTALL=%%i"
echo _VS_INSTALL=%_VS_INSTALL%
if not defined _VS_INSTALL (
  echo ERROR: vswhere did not find a VS 2022 install
  exit /b 1
)

REM Run vsdevcmd to set up the full MSVC + Windows SDK env (VCTargetsPath,
REM full INCLUDE/LIB/LIBPATH including ucrt/shared/um subdirs). Conda-build's
REM "legacy MSVC compiler setup" leaves INCLUDE missing the Windows SDK
REM headers (mscoree.h, etc.).
call "%_VS_INSTALL%\Common7\Tools\vsdevcmd.bat" -no_logo -arch=x64 || exit /b 1

REM Pre-generate the three files that build_init.cmd's SetBuildNumber.proj
REM would normally produce (it fails because GitInfo needs git + a .git dir,
REM and we have neither).
copy /Y "%RECIPE_DIR%\global.json" "%SRC_DIR%\global.json" || exit /b 1
copy /Y "%RECIPE_DIR%\Directory.Packages.props" "%SRC_DIR%\Directory.Packages.props" || exit /b 1
mkdir "%SRC_DIR%\build" 2>nul
copy /Y "%RECIPE_DIR%\wixver.props" "%SRC_DIR%\build\wixver.props" || exit /b 1

REM ============================================================================
REM Add <Culture>0x0409</Culture> to ResourceCompile's ItemDefinitionGroup in
REM src/Directory.vcxproj.props. Newer MSBuild promotes "missing Culture
REM metadata" to error MSB4096 on Directory.vcxproj.targets line 21 (where
REM ver.rc references %(Culture) for batched evaluation). Combined with WiX's
REM `-warnaserror` flag, the dtf build aborts despite SfxCA.dll being created.
powershell -NoProfile -Command "$f = '%SRC_DIR%\src\Directory.vcxproj.props'; $c = Get-Content -Raw $f; if ($c -notmatch '<Culture>') { $new = $c -replace '(</AdditionalIncludeDirectories>)(\s+</ResourceCompile>)', '$1<Culture>0x0409</Culture>$2'; if ($new -eq $c) { Write-Host 'ERROR: regex did not match -- check Directory.vcxproj.props structure' -ForegroundColor Red; exit 1 } else { Set-Content -NoNewline -Path $f -Value $new; Write-Host 'patched Directory.vcxproj.props with Culture metadata' } } else { Write-Host 'Culture already present, skipping' }" || exit /b 1

REM ============================================================================
REM Pin SDK versions inline in every <Project Sdk="..."> reference. NuGetSdk-
REM Resolver isn't reliably picking up global.json in our build env (likely a
REM walk-up issue from devbuild's per-subdir `pushd`s); inline pinning bypasses
REM the resolver entirely. Versions match what global.json.pp would have set.
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.proj,*.csproj,*.vcxproj | ForEach-Object { $c = Get-Content -Raw $_.FullName; $n = $c -replace 'Sdk=\"Microsoft.Build.Traversal\"', 'Sdk=\"Microsoft.Build.Traversal/3.2.0\"' -replace 'Sdk=\"Microsoft.Build.NoTargets\"(?!/)', 'Sdk=\"Microsoft.Build.NoTargets/3.5.6\"'; if ($c -ne $n) { Set-Content -NoNewline -Path $_.FullName -Value $n; Write-Host \"patched: $($_.FullName)\" } }" || exit /b 1

REM ============================================================================
REM Strip ARM64 ProjectReferences from _t.proj traversal files. Briefcase /
REM Anaconda installers are x86_64 only -- ARM64 isn't needed. Cross-compiling
REM ARM64 with a vsdevcmd activated for x64 produces LNK1112 (obj machine-type
REM mismatch). Skip the ARM64 build target entirely.
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.proj,*.csproj,*.vcxproj,*.wixproj | ForEach-Object { $c = Get-Content -Raw $_.FullName; $n = $c -replace '(?m)^[ \t]*<ProjectReference[^>]*Platform=ARM64[^>]*/>\s*\r?\n?', '' -replace '(?m)^[ \t]*<ProjectReference[^>]*RuntimeIdentifier=win-arm64[^>]*/>\s*\r?\n?', '' -replace 'Platforms=\"arm64,', 'Platforms=\"' -replace ',arm64,', ',' -replace ',arm64\"', '\"'; if ($c -ne $n) { Set-Content -NoNewline -Path $_.FullName -Value $n; Write-Host \"stripped ARM64 from: $($_.FullName)\" } }" || exit /b 1

REM Also strip ;win-arm64 from <RuntimeIdentifiers> lists in .csproj files
REM (e.g. wix.csproj has 'win-x86;win-x64;win-arm64'). Without this, building
REM wix.csproj cascades into wixnative.vcxproj being compiled for ARM64,
REM which fails LNK1181 because dutil/wcautil weren't built for ARM64.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.csproj | ForEach-Object { $c = Get-Content -Raw $_.FullName; $n = $c -replace ';win-arm64', '' -replace 'win-arm64;', ''; if ($c -ne $n) { Set-Content -NoNewline -Path $_.FullName -Value $n; Write-Host \"stripped win-arm64 RID from: $($_.FullName)\" } }" || exit /b 1

REM Strip ARM64 platform configurations from .sln files. wix.sln (and
REM others) define ARM64 in SolutionConfigurationPlatforms and Project-
REM ConfigurationPlatforms sections. `msbuild wix.sln` builds for ALL
REM configured platforms by default, including ARM64 -- which then tries
REM to link wixnative.vcxproj against ARM64 dutil.lib (not built).
REM Drop every line containing 'ARM64' from .sln files (line-based format).
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.sln | ForEach-Object { $lines = Get-Content $_.FullName; $out = $lines | Where-Object { $_ -notmatch 'ARM64' }; if ($out.Count -ne $lines.Count) { Set-Content -Path $_.FullName -Value $out; Write-Host \"stripped ARM64 lines from: $($_.FullName)\" } }" || exit /b 1

REM Strip lines referencing ARM64 / win-arm64 from .targets and .props
REM files. src/wix/Directory.Build.targets has <NativeLibrary> and <None>
REM items referencing \ARM64\wixnative.exe for the wix.csproj net6.0
REM RuntimeTargetsCopyLocalItems flow -- triggers wixnative.vcxproj
REM ARM64 build outside the <ProjectReference> patterns.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.targets,*.props | ForEach-Object { $lines = Get-Content $_.FullName; $out = $lines | Where-Object { $_ -notmatch 'ARM64' -and $_ -notmatch 'win-arm64' }; if ($out.Count -ne $lines.Count) { Set-Content -Path $_.FullName -Value $out; Write-Host \"stripped ARM64 lines from: $($_.FullName)\" } }" || exit /b 1

REM Delete platform-specific *_arm64.wxs files in each ext's wixlib dir.
REM WiX SDK auto-includes all .wxs files in the wixproj dir; the _arm64
REM variants set $(var.platform)=arm64 then try bindpath.<ca>.arm64,
REM which fails (we don't build ARM64 utilbe/utilca/etc) -- error WIX0103.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *_arm64.wxs,*_ARM64.wxs | ForEach-Object { Remove-Item -Force $_.FullName; Write-Host \"deleted ARM64 wxs: $($_.FullName)\" }"

REM Strip arm64 from <?foreach PLATFORM in x86;x64;arm64?> directives in
REM .wxi/.wxs files. Even with _arm64.wxs deleted, NetFx's wixlib has
REM foreach loops in the _Platform.wxi and NetCoreShared.wxs that iterate
REM x86;x64;arm64 unconditionally -- triggers bindpath.netcoresearch.arm64
REM which doesn't exist (no ARM64 native build).
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.wxi,*.wxs | ForEach-Object { $c = Get-Content -Raw $_.FullName; $n = $c -replace '(<\?foreach[^?]*);arm64', '$1' -replace '(<\?foreach[^?]*)arm64;', '$1'; if ($c -ne $n) { Set-Content -NoNewline -Path $_.FullName -Value $n; Write-Host \"stripped arm64 from foreach in: $($_.FullName)\" } }" || exit /b 1

REM Replace src/test/test.cmd with a no-op. build_all.cmd's last step is
REM `call test\test.cmd %_C% || exit /b` which builds extensive integration
REM test data (~220 bundles + MSIs). We don't need any of it -- the actual
REM wix.exe + extension nupkgs are already built by the previous subdirs.
REM Test data builds also keep hitting environment-specific failures
REM (.NET reference assembly loading, etc.) that are orthogonal to the
REM production package.
echo @exit /b 0 > "%SRC_DIR%\src\test\test.cmd"

REM ============================================================================
REM Drop legacy .NET Framework targets (net20, net35, net40) from
REM <TargetFrameworks> lists. The dev / PBP AMIs don't have .NET Framework
REM 3.5 SP1 installed (providing net20/net35 backcompat); on Server it's a
REM Windows Feature requiring offline install media. Briefcase / Anaconda
REM installers don't use these legacy custom action targets -- netstandard2.0
REM and net472 are sufficient.
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.csproj | ForEach-Object { $c = Get-Content -Raw $_.FullName; $n = $c -replace '<TargetFrameworks>([^<]*?);net20([^<]*?)</TargetFrameworks>', '<TargetFrameworks>$1$2</TargetFrameworks>' -replace '<TargetFrameworks>net20;([^<]*?)</TargetFrameworks>', '<TargetFrameworks>$1</TargetFrameworks>' -replace '<TargetFrameworks>net20</TargetFrameworks>', '<TargetFramework>net472</TargetFramework>' -replace '<TargetFrameworks>([^<]*?);net35([^<]*?)</TargetFrameworks>', '<TargetFrameworks>$1$2</TargetFrameworks>' -replace '<TargetFrameworks>net35;([^<]*?)</TargetFrameworks>', '<TargetFrameworks>$1</TargetFrameworks>' -replace '<TargetFrameworks>net35</TargetFrameworks>', '<TargetFramework>net472</TargetFramework>' -replace '<TargetFrameworks>([^<]*?);net40([^<]*?)</TargetFrameworks>', '<TargetFrameworks>$1$2</TargetFrameworks>' -replace '<TargetFrameworks>net40;([^<]*?)</TargetFrameworks>', '<TargetFrameworks>$1</TargetFrameworks>' -replace '<TargetFrameworks>net40</TargetFrameworks>', '<TargetFramework>net472</TargetFramework>'; if ($c -ne $n) { Set-Content -NoNewline -Path $_.FullName -Value $n; Write-Host \"stripped legacy frameworks from: $($_.FullName)\" } }" || exit /b 1

REM ============================================================================
REM Strip ARM64 references from .nuspec files. NuPkg packing tries to include
REM ARM64\SfxCA.dll etc., which don't exist after the ARM64 build strip.
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.nuspec | ForEach-Object { $c = Get-Content -Raw $_.FullName; $n = $c -replace '(?m)^[ \t]*<file[^>]*ARM64[^>]*/>\s*\r?\n?', ''; if ($c -ne $n) { Set-Content -NoNewline -Path $_.FullName -Value $n; Write-Host \"stripped ARM64 from nuspec: $($_.FullName)\" } }" || exit /b 1

REM ============================================================================
REM Stub out the 6 legacy test csprojs in src/dtf/test/ that reference
REM Microsoft.VisualStudio.QualityTools.UnitTestFramework (deprecated MSTest
REM v1 from VS 2010, not on our build env). Replacing with empty MSBuild
REM projects keeps dtf.sln happy without compiling any test code.
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src\dtf\test' -Recurse -Include *.csproj | ForEach-Object { Set-Content -NoNewline -Path $_.FullName -Value '<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><TargetFramework>net472</TargetFramework><IsPackable>false</IsPackable><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup></Project>'; Write-Host \"stubbed test csproj: $($_.FullName)\" }" || exit /b 1

REM ============================================================================
REM Strip `dotnet test ...` blocks from every subdir .cmd file. We don't need
REM to run tests during the build, and several test DLLs (e.g.
REM WixToolsetTest.BootstrapperApplicationApi.dll for net6.0/win-x86) need
REM dotnet runtimes we don't have (x86 hostfxr.dll). The block is a single
REM logical line spanning multiple physical lines via `^` continuations,
REM ending at `|| exit /b`. PowerShell processes line-by-line, dropping
REM lines starting with `dotnet test` through the next `|| exit /b`.
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.cmd | ForEach-Object { $lines = Get-Content $_.FullName; $out = New-Object System.Collections.ArrayList; $inTest = $false; $stripped = $false; foreach ($line in $lines) { if (-not $inTest -and $line -match '^\s*dotnet test') { $inTest = $true; $stripped = $true; if ($line -match '\|\| exit /b') { $inTest = $false }; continue }; if ($inTest) { if ($line -match '\|\| exit /b') { $inTest = $false }; continue }; [void]$out.Add($line) }; if ($stripped) { Set-Content -Path $_.FullName -Value $out; Write-Host \"stripped dotnet test from: $($_.FullName)\" } }" || exit /b 1

REM ============================================================================
REM Sanity check: dotnet + nuget reachable. (msbuild also required, but
REM not on a stable PATH location until after vsdevcmd above.)
REM ============================================================================
where dotnet || exit /b 1
where nuget || exit /b 1

REM ============================================================================
REM Run upstream build.
REM ============================================================================
REM devbuild.cmd's first step is `src\clean.cmd`, which `rd /s/q ..\build`,
REM deletes `..\global.json`, `..\Directory.Packages.props`, etc. -- wiping
REM out everything we just pre-staged. The `inc` flag skips clean.cmd.
call devbuild.cmd release inc || exit /b 1

REM Stage outputs.
mkdir "%LIBRARY_PREFIX%\wix" 2>nul
mkdir "%LIBRARY_PREFIX%\wix\sdk" 2>nul
mkdir "%LIBRARY_PREFIX%\wix\nupkgs" 2>nul

xcopy /E /I /Y "build\wix\Release\publish" "%LIBRARY_PREFIX%\wix\sdk" || exit /b 1

for %%f in (build\artifacts\WixToolset.*.wixext.*.nupkg) do (
  copy /Y "%%f" "%LIBRARY_PREFIX%\wix\nupkgs\" || exit /b 1
)

REM Self-relative shim: %~dp0 expands to the directory containing wix.bat
REM (i.e. <env>\Library\bin\). Walking up to ..\wix\sdk\wix\wix.exe gives
REM <env>\Library\wix\sdk\wix\wix.exe regardless of the env's actual path.
REM Avoids depending on %LIBRARY_PREFIX% which is conda-build-only and not
REM set during normal `conda activate`.
mkdir "%LIBRARY_BIN%" 2>nul
echo @"%%~dp0..\wix\sdk\wix\wix.exe" %%* > "%LIBRARY_BIN%\wix.bat"

REM Shut down .NET build servers (Roslyn/VBCSCompiler in particular) so they
REM release file handles in %BUILD_PREFIX% / %LIBRARY_PREFIX%. Without this,
REM conda-build's test phase fails to rename _h_env (locked DLLs).
REM `dotnet build-server shutdown` doesn't always catch VBCSCompiler -- fall
REM back to a targeted taskkill for that specific image only. Do NOT taskkill
REM dotnet.exe globally; conda-build's own helpers may be running it.
"%BUILD_PREFIX%\dotnet\dotnet.exe" build-server shutdown
taskkill /F /IM VBCSCompiler.exe 2>nul

endlocal
