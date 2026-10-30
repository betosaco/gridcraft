# DisHub Cálculo

Monte Carlo simulation and 95 actuarial worksheet functions in a Rust-native spreadsheet.
This is an independently distributed edition based on **GridCraft by the ArtCraft team and community**, not an official ArtCraft build.

- Experimental preview track: **0.1.0-preview.1** (numeric MSI **0.1.0**).
- Calculation base: GridCraft 0.13.0, commit `d26063521acd8afb375db15eb46467bef0d9ab16`.
- Product information, tutorials and verified downloads: https://www.dishub.city/actuarial.
- Calculation documentation: [Monte Carlo](docs/monte-carlo.md), [count distributions and AR1](docs/monte-carlo-processes.md), [actuarial functions](docs/actuarial.md), [method contracts](docs/actuarial-scientific.md), [validation scope](docs/actuarial-validation.md).

## Distribution status

The distribution scripts and identity changes are prepared for review. **No public installer is available from this source merely because a packaging script exists.** Windows and Mac artifacts must be built, checked on their announced architecture, and published with hashes and accurate signature/notarization information. The approved initial channel is experimental: Mac ad-hoc signed and not notarized, Windows unsigned. This is not commercial signing; operating systems may warn or block installation. No protection-bypass instructions are provided.

Updates are manual. This edition does not run GridCraft's automatic updater or executable-replacement helper. Download a new verified release from the DisHub page when one is available. It has separate app/settings/installer identifiers so it can coexist with GridCraft without migrating or overwriting that installation's preferences.

See [distribution contract and verification](docs/distribution.md) and [edition metadata](distribution/edition.json). The internal Cargo package/binary names remain `gridcraft`/`gridcraft-cli`; packaged executables identify this edition.

## Calculation and reproducibility

Keep the workbook, version, input assumptions and simulation configuration together. A controlled seed repeats supported sampling, not arbitrary `RAND`, `NOW` or external data. Review each method's documented domain and statistical assumptions. Neither a simulation report nor a test count establishes regulatory certification or adequacy of a model for every purpose.

Public examples are synthetic. No private financial workbook or customer data is included.

## Source and licences

Original project: https://github.com/storytold/gridcraft. Contribution history and upstream authorship remain in this repository. Source is available under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE); also see [NOTICE](NOTICE) and [asset attribution](ATTRIBUTION.md). Third-party font notices accompany packaged builds when embedded.

The original open-source green spreadsheet icon is retained under its [MIT/Apache licence](assets/app-icon/LICENSE.txt). Restricted ArtCraft artwork has been removed from this modified distribution; its licence text is preserved for provenance. DisHub Cálculo does not claim sponsorship, certification or support by the ArtCraft team.
