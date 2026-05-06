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
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.proj | ForEach-Object { $c = Get-Content -Raw $_.FullName; $n = $c -replace '(?m)^[ \t]*<ProjectReference[^>]*Platform=ARM64[^>]*/>\s*\r?\n?', ''; if ($c -ne $n) { Set-Content -NoNewline -Path $_.FullName -Value $n; Write-Host \"stripped ARM64 from: $($_.FullName)\" } }" || exit /b 1

REM ============================================================================
REM Drop .NET Framework 2.0 (net20) from <TargetFrameworks> lists. The PBP /
REM dev AMI doesn't have .NET Framework 3.5 SP1 installed (provides net20
REM backcompat); installing it requires a Windows Feature with offline media.
REM Briefcase/Anaconda installers don't use net20-targeted custom actions.
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.csproj | ForEach-Object { $c = Get-Content -Raw $_.FullName; $n = $c -replace '<TargetFrameworks>([^<]*?);net20([^<]*?)</TargetFrameworks>', '<TargetFrameworks>$1$2</TargetFrameworks>' -replace '<TargetFrameworks>net20;([^<]*?)</TargetFrameworks>', '<TargetFrameworks>$1</TargetFrameworks>' -replace '<TargetFrameworks>net20</TargetFrameworks>', '<TargetFramework>net472</TargetFramework>'; if ($c -ne $n) { Set-Content -NoNewline -Path $_.FullName -Value $n; Write-Host \"stripped net20 from: $($_.FullName)\" } }" || exit /b 1

REM ============================================================================
REM Diagnostics -- keep until build is green; trim afterwards.
REM ============================================================================
where dotnet || exit /b 1
where nuget || exit /b 1
where msbuild
echo VCTargetsPath=%VCTargetsPath%
echo MSBuildSDKsPath=%MSBuildSDKsPath%
echo VCToolsInstallDir=%VCToolsInstallDir%
echo WindowsSdkDir=%WindowsSdkDir%
echo INCLUDE=%INCLUDE%
echo --- mscoree.h availability check ---
powershell -NoProfile -Command "if (Test-Path \"$env:WindowsSdkDir\Include\$env:WindowsSDKVersion`um\mscoree.h\") { 'FOUND in WindowsSDK um' } else { 'MISSING in WindowsSDK um' }"
echo --- NETFXSDK versions present? ---
powershell -NoProfile -Command "if (Test-Path 'C:\Program Files (x86)\Windows Kits\NETFXSDK') { Get-ChildItem 'C:\Program Files (x86)\Windows Kits\NETFXSDK' -Name } else { 'NETFXSDK not installed' }"
echo --- filesystem search for mscoree.h ---
powershell -NoProfile -Command "Get-ChildItem -Path 'C:\Program Files (x86)\Windows Kits' -Filter mscoree.h -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName"
echo --- contents of dotnet SDK Sdks/ ---
if exist "%MSBuildSDKsPath%" (dir /B "%MSBuildSDKsPath%") else (echo MISSING: %MSBuildSDKsPath%)
echo --- contents of Microsoft.NET.Sdk/Sdk ---
if exist "%MSBuildSDKsPath%\Microsoft.NET.Sdk\Sdk" (dir /B "%MSBuildSDKsPath%\Microsoft.NET.Sdk\Sdk") else (echo MISSING: %MSBuildSDKsPath%\Microsoft.NET.Sdk\Sdk)
echo ====================

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

mkdir "%LIBRARY_BIN%" 2>nul
echo @"%%LIBRARY_PREFIX%%\wix\sdk\wix\wix.exe" %%* > "%LIBRARY_BIN%\wix.bat"

endlocal
