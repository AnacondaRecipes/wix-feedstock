About wix
=========

Home: https://wixtoolset.org/

Package license: MS-RL

Feedstock license: [BSD-3-Clause](https://github.com/AnacondaRecipes/wix-feedstock/blob/main/LICENSE.txt)

Summary: WiX Toolset — create Windows Installer (MSI) packages

Documentation: https://docs.firegiant.com/wixtoolset/

The WiX Toolset is a set of tools for building Windows Installer (MSI) packages
from XML source. This feedstock packages the v5.x `wix.exe` command-line driver,
the WiX SDK assemblies, and the standard set of WiX extensions
(Util, Bal, NetFx, ComPlus, Dependency, DirectX, Firewall, Http, Iis, Msmq,
PowerShell, Sql, UI, VisualStudio). Built from source.

This package is a build-time dependency of `briefcase-feedstock`.

Packages
--------

| Name | Description |
| --- | --- |
| wix | WiX Toolset CLI (`wix.exe`) plus SDK assemblies and standard extensions |

Installing wix
==============

```
conda install wix
```

Feedstock Maintainers
=====================

* [@xkong-anaconda](https://github.com/xkong-anaconda/)
