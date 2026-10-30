# DisHub Cálculo distribution contract

This branch is a separate distribution of the validated GridCraft calculation base. It does not alter actuarial functions, simulation algorithms or engine command semantics. Upstream contribution branches and the user's installed GridCraft application are outside its ownership.

## Identity and version

- Product/publisher: DisHub Cálculo / DisHub.
- Bundle/app ID: `city.dishub.calculo`; settings: `DisHubCalculo` under the platform user-settings root (`dishub-calculo` under XDG on Linux).
- macOS: `DisHub Cálculo.app`, internal executable/icon name `DisHubCalculo`, packaged CLI `dishub-calculo-cli`.
- Windows: `dishub-calculo.exe`, `dishub-calculo-cli.exe`, `Software\DisHubCalculo`, `DisHubCalculo.Workbook` and `DisHubCalculo.TextData`. The new stable MSI UpgradeCode is `05C18FF9-F9BE-5BD2-968F-4C229F64BD17`; the app component GUID is `3930E8EA-AA9C-5DB4-94C3-124AC6EBE3A1`. Neither matches GridCraft's identity.
- Experimental preview `0.1.0-preview.1`, numeric MSI `0.1.0`; original base GridCraft `0.13.0` / `d26063521acd8afb375db15eb46467bef0d9ab16` is separately identified in About and `distribution/edition.json`.
- Do not publish several preview/stable MSIs under the same numeric ProductVersion. The approved first publication is an experimental preview after platform gates pass. After publishing its MSI `0.1.0`, allocate a monotonically newer numeric version for the next public installer, at least `0.1.1`, rather than reusing `0.1.0` for a later preview or stable release. Match source version, runtime version, package version and published manifest.

## Manual updates

Startup-check requests are ignored, and the existing explicit update command opens only https://www.dishub.city/actuarial. No `craft_update::Updater` or upstream self-replacement helper runs. User-controlled documents are not closed for an update. The upstream dependency may remain in the lockfile, but its automatic-update path is not called by this edition.

## Build candidates, not availability promises

Internal Cargo binary names stay `gridcraft` and `gridcraft-cli`. The packaging scripts rename the installed/public payloads. Both package scripts require the chosen distribution version to match Cargo metadata.

After root grants a build slot, macOS candidates can be prepared with `packaging/macos/package.sh --arch aarch64` (or x86_64/universal only when those targets are actually built and tested). Windows requires an authorized Windows MSVC/SDK/WiX5.0.2 environment; use `packaging/windows/package.ps1 -Arch x64`. `-SkipBuild`/`--skip-build` never proves that an old binary matches this source; verify actual binary version and discovery first.

The human approved experimental publication with Mac ad-hoc signing and no notarization, and unsigned Windows artifacts. Scripts preserve existing signing behavior and record the actual result. Never advertise these previews as commercially signed/notarized or provide instructions to bypass operating-system protection. Exit 0 does **not** mean publicly trusted signing. Generated `*.manifest.json` records actual file hashes, sizes and signature/notarization status, marks artifacts as candidates, and sets `publiclyAvailable:false`/`url:null`. A public release must separately verify its downloaded files and set the website's availability only afterward. Never copy credentials/certificates from upstream or print their values.

No source/release URL is fabricated here. The publisher must commit the reviewed distribution changes, record the actual source commit, build immutable release assets and publish matching source, release notes and checksums. A dirty-source candidate cannot be described as built from a clean public commit.

## Required gates before public downloads

1. Independent source review: no ArtCraft artwork/official-product claim; original legal/credits and font notices remain; no upstream updater or installer/settings collision.
2. Native focused regressions: startup is silent, explicit manual command opens the edition page, settings do not alias upstream; Windows compiled-policy checks reject upstream UpgradeCode/registration.
3. First experimental targets are Windows x64 and Mac ARM64 only. Build each advertised target natively; missing targets stay unavailable. Intel/universal Mac and Windows ARM64/x86 remain pending and have no download CTA until their own gates pass.
4. Windows x64: native build, CLI discovery of all 95 ACT and six MC functions, new MSI install/uninstall, independent identity and coexistence with GridCraft on an authorized Windows runner. Metadata-only fixtures do not replace this real-payload gate.
5. Mac ARM64: create and mount the DMG, inspect the bundle/architecture, launch the independent app, verify its separate preferences namespace, licences, hashes and 95 ACT/six MC discovery. Do not replace GridCraft or its settings. Label its actual ad-hoc signature and lack of notarization explicitly; no commercially trusted signature or smooth installation is claimed.
6. Public URLs return the correct immutable artifact; downloaded byte count/SHA256 agree with the release/website manifest. Labels accurately distinguish signed/notarized/experimental artifacts. Missing targets stay unavailable.

No earlier DisHub Cálculo release exists. Same-edition upgrade testing and broader installer cancellation/rollback/optional-association qualification are **PENDING future qualification**, not passed and not prerequisites that require inventing an older release for the first preview. Public MSI versions must still increase monotonically for later releases as specified above. Native seeded/source-preservation/refusal/undo regression coverage remains a separately recorded calculation gate; it is not inferred from discovery counts or installer success.

The initial page can explain methods and pending availability while these gates run, but must not show a working download button for an unbuilt or unverified platform.

## MCP and application coexistence

The existing transport remains compatible: explicit `--connect PORT`/`send` chooses a loopback control endpoint; `mcp` without `--connect` is headless. Token files remain keyed by port under the original protocol's private token directory. The server binds the port before writing its token, so a second app on that occupied port fails rather than replacing that token. Choose different explicit control ports when running both applications. No automatic discovery/attachment to another product is implemented here. MCP protocol/server naming and `GRIDCRAFT_CONTROL_*` environment names are retained for compatibility; this is not a claim of a separate security namespace or process/tenant isolation.
