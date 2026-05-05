@echo on

:: Put the build-helper nuget.exe on PATH for upstream's devbuild.cmd.
:: nuget.exe lives in %SRC_DIR%\build_helpers and is NOT staged into %PREFIX%.
set "PATH=%SRC_DIR%\build_helpers;%PATH%"

:: Use dotnet from the dotnet-feedstock build dep (already on PATH via DOTNET_ROOT).
:: Tell upstream to use this dotnet rather than searching system locations.
where dotnet || exit /b 1
where nuget || exit /b 1

:: Run the upstream build orchestrator.
:: devbuild.cmd auto-launches a VS Developer Command Prompt via vswhere; the
:: PBP win-64 AMI must have VS2022 (MSVC v143) + .NET Framework 4.7.2 SDK +
:: 4.6.2/4.7.2 targeting packs installed for this to succeed.
call devbuild.cmd release || exit /b 1

:: Stage outputs into %LIBRARY_PREFIX%\wix\.
::   sdk\        - publish tree (wix.exe, BuildTasks, burn, runtime)
::   nupkgs\     - extension .nupkg artifacts (Util, Bal, NetFx, ...)
mkdir "%LIBRARY_PREFIX%\wix" 2>nul
mkdir "%LIBRARY_PREFIX%\wix\sdk" 2>nul
mkdir "%LIBRARY_PREFIX%\wix\nupkgs" 2>nul

xcopy /E /I /Y "build\wix\Release\publish" "%LIBRARY_PREFIX%\wix\sdk" || exit /b 1

:: Copy only the WixToolset.*.wixext.*.nupkg files (drop test/internal nupkgs).
for %%f in (build\artifacts\WixToolset.*.wixext.*.nupkg) do (
  copy /Y "%%f" "%LIBRARY_PREFIX%\wix\nupkgs\" || exit /b 1
)

:: Put wix.exe on PATH via a tiny shim. The actual binary stays in sdk\wix\
:: alongside its .NET 6 dependencies (so the apphost can find them).
mkdir "%LIBRARY_BIN%" 2>nul
> "%LIBRARY_BIN%\wix.bat" echo @"%%LIBRARY_PREFIX%%\wix\sdk\wix\wix.exe" %%*

:: Upstream LICENSE.TXT is at %SRC_DIR%\LICENSE.TXT (extracted from the source
:: tarball) — picked up by `license_file: LICENSE.TXT` in meta.yaml.
