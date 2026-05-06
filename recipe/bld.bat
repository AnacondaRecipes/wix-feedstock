@echo on
setlocal

REM ============================================================================
REM Put build helpers (nuget.exe + msbuild shim) at the front of PATH.
REM ============================================================================
set "PATH=%SRC_DIR%\build_helpers;%PATH%"

REM Create a thin msbuild.cmd shim that defers to `dotnet msbuild`. The PBP
REM win-64 AMI ships VS2022 BuildTools without the .NET SDK component, so VS's
REM MSBuild can't load Microsoft.NET.Sdk / WorkloadAutoImportPropsLocator nor
REM resolve package-based SDKs. `dotnet msbuild` from our conda-installed
REM dotnet 8 SDK has the proper resolver pipeline.
echo @"%BUILD_PREFIX%\dotnet\dotnet.exe" msbuild %%* > "%SRC_DIR%\build_helpers\msbuild.cmd"

REM Tell upstream's devbuild.cmd to skip the vsdevcmd re-activation; conda-build
REM already set up MSVC env vars (INCLUDE / LIB / LIBPATH / VCToolsInstallDir)
REM during legacy compiler setup, and skipping keeps our msbuild.cmd shim
REM ahead of VS's msbuild.exe in PATH.
set "WixSkipVsDevCmd=1"

set "DOTNET_ROOT=%BUILD_PREFIX%\dotnet"

REM Pin SDK versions for MSBuild's resolver.
REM   - sdk.version: pins .NET SDK to the conda-installed 8.0.100
REM   - msbuild-sdks: Microsoft.Build.Traversal isn't pinned anywhere in WiX
REM     v5.0.2 source; on upstream's CI this comes from the bundled VS
REM     install. We pick 4.1.0 (released Apr 2024, contemporaneous with
REM     WiX 5.0.2 from Jul 2024). The NuGetSdkResolver will fetch it.
echo {"sdk": {"version": "8.0.100", "rollForward": "latestFeature"}, "msbuild-sdks": {"Microsoft.Build.Traversal": "4.1.0"}} > global.json

REM ============================================================================
REM Diagnostics -- keep these in until the build is green; trim afterwards.
REM ============================================================================
where dotnet || exit /b 1
where nuget || exit /b 1
where msbuild
echo DOTNET_ROOT=%DOTNET_ROOT%
echo WixSkipVsDevCmd=%WixSkipVsDevCmd%
echo VCToolsInstallDir=%VCToolsInstallDir%
echo --- dotnet --info ---
dotnet --info
echo --- global.json ---
type global.json
echo ====================

REM ============================================================================
REM Run upstream build.
REM ============================================================================
call devbuild.cmd release || exit /b 1

REM Stage outputs.
mkdir "%LIBRARY_PREFIX%\wix" 2>nul
mkdir "%LIBRARY_PREFIX%\wix\sdk" 2>nul
mkdir "%LIBRARY_PREFIX%\wix\nupkgs" 2>nul

xcopy /E /I /Y "build\wix\Release\publish" "%LIBRARY_PREFIX%\wix\sdk" || exit /b 1

for %%f in (build\artifacts\WixToolset.*.wixext.*.nupkg) do (
  copy /Y "%%f" "%LIBRARY_PREFIX%\wix\nupkgs\" || exit /b 1
)

REM Tiny shim on PATH that calls into sdk\wix\wix.exe.
mkdir "%LIBRARY_BIN%" 2>nul
echo @"%%LIBRARY_PREFIX%%\wix\sdk\wix\wix.exe" %%* > "%LIBRARY_BIN%\wix.bat"

endlocal
