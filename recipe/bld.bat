@echo on
setlocal

REM ============================================================================
REM Stage build helpers and pre-generated MSBuild config.
REM ============================================================================

set "PATH=%SRC_DIR%\build_helpers;%PATH%"

REM msbuild.cmd shim that defers to `dotnet msbuild`. The PBP win-64 AMI ships
REM VS2022 BuildTools without the .NET SDK component.
echo @"%BUILD_PREFIX%\dotnet\dotnet.exe" msbuild %%* > "%SRC_DIR%\build_helpers\msbuild.cmd"

set "WixSkipVsDevCmd=1"
set "DOTNET_ROOT=%BUILD_PREFIX%\dotnet"

REM Conda-build's legacy MSVC setup sets VCToolsInstallDir / INCLUDE / LIB but
REM NOT VCTargetsPath, which vcxproj projects need to import Microsoft.Cpp.*
REM .props from <VS>\MSBuild\Microsoft\VC\v170\. Without it, the imports
REM resolve to literal "C:\Microsoft.Cpp.Default.props" and fail. Derive the
REM path via vswhere.
REM `-products *` is required to match BuildTools (default vswhere only matches
REM Community/Pro/Enterprise products).
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -products * -version [17.0^,18.0^) -property installationPath`) do set "_VS_INSTALL=%%i"
echo _VS_INSTALL=%_VS_INSTALL%
if not defined _VS_INSTALL (
  echo ERROR: vswhere did not find a VS 2022 install
  exit /b 1
)
set "VCTargetsPath=%_VS_INSTALL%\MSBuild\Microsoft\VC\v170\"

REM Pre-generate the three files that build_init.cmd's SetBuildNumber.proj
REM would normally produce (it fails because GitInfo needs git + a .git dir,
REM and we have neither).
copy /Y "%RECIPE_DIR%\global.json" "%SRC_DIR%\global.json" || exit /b 1
copy /Y "%RECIPE_DIR%\Directory.Packages.props" "%SRC_DIR%\Directory.Packages.props" || exit /b 1
mkdir "%SRC_DIR%\build" 2>nul
copy /Y "%RECIPE_DIR%\wixver.props" "%SRC_DIR%\build\wixver.props" || exit /b 1

REM ============================================================================
REM Pin SDK versions inline in every <Project Sdk="..."> reference. NuGetSdk-
REM Resolver isn't reliably picking up global.json in our build env (likely a
REM walk-up issue from devbuild's per-subdir `pushd`s); inline pinning bypasses
REM the resolver entirely. Versions match what global.json.pp would have set.
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.proj,*.csproj,*.vcxproj | ForEach-Object { $c = Get-Content -Raw $_.FullName; $n = $c -replace 'Sdk=\"Microsoft.Build.Traversal\"', 'Sdk=\"Microsoft.Build.Traversal/3.2.0\"' -replace 'Sdk=\"Microsoft.Build.NoTargets\"(?!/)', 'Sdk=\"Microsoft.Build.NoTargets/3.5.6\"'; if ($c -ne $n) { Set-Content -NoNewline -Path $_.FullName -Value $n; Write-Host \"patched: $($_.FullName)\" } }" || exit /b 1

REM ============================================================================
REM Diagnostics -- keep until build is green; trim afterwards.
REM ============================================================================
where dotnet || exit /b 1
where nuget || exit /b 1
where msbuild
echo VCTargetsPath=%VCTargetsPath%
echo --- pinned Sdk references in src/ ---
powershell -NoProfile -Command "Get-ChildItem -Path '%SRC_DIR%\src' -Recurse -Include *.proj | Select-String -Pattern 'Microsoft.Build.Traversal' | Select-Object -First 5"
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
