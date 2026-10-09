# Changelog

## [3.0.0](https://github.com/2giosangmitom/sqmeow.nvim/compare/v2.5.0...v3.0.0) (2026-10-09)


### ⚠ BREAKING CHANGES

* **result:** filter and sort retained rows uniformly
* **export:** write CSV and JSON with Polars
* **result:** use Polars for retained views

### Features

* browse relationships with native drivers ([738aab0](https://github.com/2giosangmitom/sqmeow.nvim/commit/738aab099d8ff2345052677e0ad37aba3b4c5730))
* **export:** write CSV and JSON with Polars ([ebb0b26](https://github.com/2giosangmitom/sqmeow.nvim/commit/ebb0b26791df0c1a88dfd8b6a3e65b227cfd41eb))
* **query:** add parameterized scratchpads ([1cf3a2a](https://github.com/2giosangmitom/sqmeow.nvim/commit/1cf3a2a68e05607fd7f73659df92fd45357e1e56))
* **query:** bind parameters across all adapters ([27082d1](https://github.com/2giosangmitom/sqmeow.nvim/commit/27082d1e9385c1b1f12522c9bfb17d78f53ee8fb))
* **result:** filter and sort retained rows uniformly ([0bd5891](https://github.com/2giosangmitom/sqmeow.nvim/commit/0bd589115e9f00a31e253132fb8b2cbfc960f17d))
* **result:** unify view requests ([f78a1ef](https://github.com/2giosangmitom/sqmeow.nvim/commit/f78a1ef50d1ff115738bbe089ac7dd76123db087))
* **result:** use Polars for retained views ([2c1f30e](https://github.com/2giosangmitom/sqmeow.nvim/commit/2c1f30ecef0414b193313be354d3ffd5cfd68a43))
* **scratchpads:** add project-local query files ([226e81d](https://github.com/2giosangmitom/sqmeow.nvim/commit/226e81d375b4e4f0c8499f0c1f666084798e8337))
* support project dotenv files and connection URLs ([c1287db](https://github.com/2giosangmitom/sqmeow.nvim/commit/c1287dbcb53f6a398969f463da1a869a3de06bd9))
* **view:** aggregate retained snapshots with Polars ([b66fb37](https://github.com/2giosangmitom/sqmeow.nvim/commit/b66fb3781cfe4bd29b8312f92feea8eafb5e55b6))


### Fixes

* **adapters:** preserve actual cancellation outcomes ([80dd26f](https://github.com/2giosangmitom/sqmeow.nvim/commit/80dd26fd0dc895a1bdcf016300f3149bf2301366))
* **adapters:** preserve writes and result schemas ([2f723fc](https://github.com/2giosangmitom/sqmeow.nvim/commit/2f723fcf68ced38c4046dee03e3831e0d9d89593))
* **build:** link Nix database libraries ([190158d](https://github.com/2giosangmitom/sqmeow.nvim/commit/190158de43e214f7c594a9881295130d94a02b7a))
* fence cancellation and retain batch results ([220960f](https://github.com/2giosangmitom/sqmeow.nvim/commit/220960f4b40facfcb74eedddd9fdfdd4d0e7cd5f))
* **history:** exclude failed runs and yank commands ([dfccefb](https://github.com/2giosangmitom/sqmeow.nvim/commit/dfccefb30113fcde9ce15b58a567e5eaf4a0d9d3))
* nil guards, rpc strictness, archive and float handling ([45430fb](https://github.com/2giosangmitom/sqmeow.nvim/commit/45430fbe2180bfa4f53a1b254104d0889aa02c97))
* retain query results and focus adapter tests ([520071f](https://github.com/2giosangmitom/sqmeow.nvim/commit/520071f0336da03f86253a07fc57d5943feca8ed))
* **view:** correct aggregate Lua types ([b02f0dd](https://github.com/2giosangmitom/sqmeow.nvim/commit/b02f0dda71be3d28fd5c65b56f1ee8d42c8a17a1))


### Performance

* **db:** reduce text scan and buffer overhead ([eb04e6c](https://github.com/2giosangmitom/sqmeow.nvim/commit/eb04e6c3a00ab6c722624b944491c3ef9e08e0b2))
* **db:** retain native Polars columns ([0fb941e](https://github.com/2giosangmitom/sqmeow.nvim/commit/0fb941e39251a34a7d076aeb0e82a808714982e8))
* **db:** share retained frames and cache views ([82a718e](https://github.com/2giosangmitom/sqmeow.nvim/commit/82a718e4eb6318b02b1374b7b42f62d8db284f13))
* **rpc:** encode result pages by native column ([01d0c8e](https://github.com/2giosangmitom/sqmeow.nvim/commit/01d0c8e5ab94ba9678f98fd8eedf0a6c5ee78155))
* **ui:** avoid redundant grid width scans ([3e4934e](https://github.com/2giosangmitom/sqmeow.nvim/commit/3e4934e367da2a81e3c702ec581c4a76b76aef9a))
* **view:** avoid intermediate aggregate gathers ([8b711e5](https://github.com/2giosangmitom/sqmeow.nvim/commit/8b711e510a44ed8e814bd901b72d02da60a13a9e))


### Refactoring

* declare async Adapter methods with async-trait ([5630f2d](https://github.com/2giosangmitom/sqmeow.nvim/commit/5630f2d16a35422f85f3619722f79ba92c59503d))
* measure column widths in the editor, not the engine ([7854d62](https://github.com/2giosangmitom/sqmeow.nvim/commit/7854d624f0147bf16499d941c377fc3a94742f23))
* simplify connection sources and preview controls ([85f9dcd](https://github.com/2giosangmitom/sqmeow.nvim/commit/85f9dcdcfb6aa6d50702f54628e2441078af9bf5))


### Documentation

* clarify PR and issue templates ([96b535a](https://github.com/2giosangmitom/sqmeow.nvim/commit/96b535a5d7da3d5ff1469a4df6334d038e3da196))
* correct the compile from source ([a5daafd](https://github.com/2giosangmitom/sqmeow.nvim/commit/a5daafdad34146e9b089df03212269b2afe74804))
* credit Squix workflow ideas ([f3365ef](https://github.com/2giosangmitom/sqmeow.nvim/commit/f3365efee6d94efa1a91609c25af78f833a84c1e))
* improve documents ([0255e01](https://github.com/2giosangmitom/sqmeow.nvim/commit/0255e01d13c51bfd0dc612a4f09e01666930c824))
* improve readme and contributing guide ([b03eae0](https://github.com/2giosangmitom/sqmeow.nvim/commit/b03eae052511f95f832fed5b8ebc7f3d31192340))
* simplify README and explain acknowledgments ([9f983ff](https://github.com/2giosangmitom/sqmeow.nvim/commit/9f983ffa0cc752fa67de8772baf7fcf76564ebc3))
* trim filler from comments and guides ([f8feb50](https://github.com/2giosangmitom/sqmeow.nvim/commit/f8feb50a900b906afc93f517b6572479d8a678b5))
* update CONTRIBUTING.md ([9f09caf](https://github.com/2giosangmitom/sqmeow.nvim/commit/9f09caf47e4c21e840be42dbae1f294eb0602ae8))
* update doc ([72b9b5b](https://github.com/2giosangmitom/sqmeow.nvim/commit/72b9b5bdbb98e24b3910a748e9f1491f2faaf68d))
* update README ([0a1aa2e](https://github.com/2giosangmitom/sqmeow.nvim/commit/0a1aa2e7bed884b6cc48e9e123eaede1b00824e6))

## [2.5.0](https://github.com/2giosangmitom/sqmeow.nvim/compare/v2.4.0...v2.5.0) (2026-10-04)


### Features

* **completion:** add auto completion ([01cf139](https://github.com/2giosangmitom/sqmeow.nvim/commit/01cf1390f4588a4e8c0115c618a784d88e653de9)), closes [#41](https://github.com/2giosangmitom/sqmeow.nvim/issues/41)
* **drawer:** allow distinct preview buffers per relation and prevent silent data loss on modified queries ([#62](https://github.com/2giosangmitom/sqmeow.nvim/issues/62)) ([e08832b](https://github.com/2giosangmitom/sqmeow.nvim/commit/e08832b9d12c41254ec3e18bfe71ad42dc7b9a28))
* **drawer:** respect ui.result.page_size for relation preview ([#64](https://github.com/2giosangmitom/sqmeow.nvim/issues/64)) ([c620d23](https://github.com/2giosangmitom/sqmeow.nvim/commit/c620d23613d7ab9b68e7e381c9916ed24d5373a9))
* **install:** don't spam install progress ([1a74cbd](https://github.com/2giosangmitom/sqmeow.nvim/commit/1a74cbda5deff05e64164dfe3e6b00b116925307))
* support load connections from local project config ([#66](https://github.com/2giosangmitom/sqmeow.nvim/issues/66)) ([11afbb8](https://github.com/2giosangmitom/sqmeow.nvim/commit/11afbb88a2bb8f39d99995b43fd8e49ffbc6d3f0))


### Fixes

* **drawer:** make preview buffer listed ([66a8a49](https://github.com/2giosangmitom/sqmeow.nvim/commit/66a8a491c68a01c3d909e600b39bdf3b6ecbca32)), closes [#59](https://github.com/2giosangmitom/sqmeow.nvim/issues/59)
* **install:** read manifest file at install time for default version ([950d037](https://github.com/2giosangmitom/sqmeow.nvim/commit/950d0377d6b4f023abf4a9427586b252ac832133)), closes [#65](https://github.com/2giosangmitom/sqmeow.nvim/issues/65)
* run exact selections and harden query safeguards ([3dfd81b](https://github.com/2giosangmitom/sqmeow.nvim/commit/3dfd81bfe81f0da54b2952e80153e07c0ff14d05))
* tests ([40e83df](https://github.com/2giosangmitom/sqmeow.nvim/commit/40e83df4a0de5b4a9489884c1762ac13725758cc))
* tests ([e9b967c](https://github.com/2giosangmitom/sqmeow.nvim/commit/e9b967ca168fdb62c75645e728e6ce94ee950213))


### Refactoring

* group server/rpc/api, drop re-exports and dead code ([#68](https://github.com/2giosangmitom/sqmeow.nvim/issues/68)) ([ad9d342](https://github.com/2giosangmitom/sqmeow.nvim/commit/ad9d3421951de93c22c57fd1d98beb5d6faf341c))


### Documentation

* add contribution guide and update README ([9ba03d7](https://github.com/2giosangmitom/sqmeow.nvim/commit/9ba03d75900bbd979083937b21839a0722696bd2))

## [2.4.0](https://github.com/2giosangmitom/sqmeow.nvim/compare/v2.3.0...v2.4.0) (2026-09-30)


### Features

* add mssql adapter ([#58](https://github.com/2giosangmitom/sqmeow.nvim/issues/58)) ([a65457a](https://github.com/2giosangmitom/sqmeow.nvim/commit/a65457adcb06ee093803318bd90fa3c69c23d972))
* **drawer:** add scratchpads grouping ([#51](https://github.com/2giosangmitom/sqmeow.nvim/issues/51)) ([90a4212](https://github.com/2giosangmitom/sqmeow.nvim/commit/90a4212040e70835a5977c38887d659d212ff566))
* **drawer:** allow configuring drawer placement on the right ([#39](https://github.com/2giosangmitom/sqmeow.nvim/issues/39)) ([97ed6ab](https://github.com/2giosangmitom/sqmeow.nvim/commit/97ed6abf11dd119c865cdb673a79a4f634720946))
* **drawer:** preview relation in an in-memory editor buffer ([#49](https://github.com/2giosangmitom/sqmeow.nvim/issues/49)) ([403cef1](https://github.com/2giosangmitom/sqmeow.nvim/commit/403cef1988cdd82c46a212802e054f241db587e7))
* **drawer:** re-bind active editor buffer to selected connection on use ([#50](https://github.com/2giosangmitom/sqmeow.nvim/issues/50)) ([a299288](https://github.com/2giosangmitom/sqmeow.nvim/commit/a2992883ec3ae2feb21b0c6354588f417ad112f0))
* **result:** pin column headers when scrolling (sticky header) & active column in winbar ([#44](https://github.com/2giosangmitom/sqmeow.nvim/issues/44)) ([e2a9d5e](https://github.com/2giosangmitom/sqmeow.nvim/commit/e2a9d5ee2da8a43f1690c0439670d3a06ec711eb))
* **table:** add actions and keymaps to navigate horizontally between columns ([#38](https://github.com/2giosangmitom/sqmeow.nvim/issues/38)) ([c6197ec](https://github.com/2giosangmitom/sqmeow.nvim/commit/c6197ec5f74e46b8225ef9dac1d87fc695072611))


### Fixes

* **api:** reuse open connection in connect_named ([#36](https://github.com/2giosangmitom/sqmeow.nvim/issues/36)) ([a6e0f8c](https://github.com/2giosangmitom/sqmeow.nvim/commit/a6e0f8c8e39323bd0b1ee901a92abd24a3eb3c43))
* **commands:** support cluster databases in :Sqmeow use ([#57](https://github.com/2giosangmitom/sqmeow.nvim/issues/57)) ([74ae98e](https://github.com/2giosangmitom/sqmeow.nvim/commit/74ae98e082092f419e39cd5ddc89c44717467dc9))
* **drawer:** activate child connections on expand and allow use on descendant nodes ([#48](https://github.com/2giosangmitom/sqmeow.nvim/issues/48)) ([c78005a](https://github.com/2giosangmitom/sqmeow.nvim/commit/c78005ac189b2569e9fa3f64d794b49298153452))
* lint ([7787aec](https://github.com/2giosangmitom/sqmeow.nvim/commit/7787aec9f207f4f8913b53af3de1e7b03d0751d4))


### Documentation

* update SSH section ([45085d1](https://github.com/2giosangmitom/sqmeow.nvim/commit/45085d1a20d125a6749e303b662a57027899d196)), closes [#30](https://github.com/2giosangmitom/sqmeow.nvim/issues/30)

## [2.3.0](https://github.com/2giosangmitom/sqmeow.nvim/compare/v2.2.0...v2.3.0) (2026-09-24)


### Features

* **oracle:** add Oracle Database support ([#29](https://github.com/2giosangmitom/sqmeow.nvim/issues/29)) ([2d7ef9d](https://github.com/2giosangmitom/sqmeow.nvim/commit/2d7ef9d2a2ce10a89a2338a7a963f050a33d9d22))


### Fixes

* **oracle:** tolerate non-canonical NUMBER on close ([38621ed](https://github.com/2giosangmitom/sqmeow.nvim/commit/38621ed03833f416e9081012ccc3e8f483b7315a))


### Documentation

* update lazy install snippet ([7ea1bfb](https://github.com/2giosangmitom/sqmeow.nvim/commit/7ea1bfb6cdb0d68903b765c245a3ce140d7dfdfe))

## [2.2.0](https://github.com/2giosangmitom/sqmeow.nvim/compare/v2.1.0...v2.2.0) (2026-09-19)


### Features

* **edit:** cancel and time out applying changes ([c80bfe2](https://github.com/2giosangmitom/sqmeow.nvim/commit/c80bfe22554426f6efb6c55cc5e882c9de77b8fe))
* **result:** draw staged edits like a diff ([5f3f95a](https://github.com/2giosangmitom/sqmeow.nvim/commit/5f3f95a103d9814e27e29cfe5a5370bff737d44a))
* support ClickHouse and SurrealDB ([#22](https://github.com/2giosangmitom/sqmeow.nvim/issues/22)) ([cf21810](https://github.com/2giosangmitom/sqmeow.nvim/commit/cf21810719be246e10c139f080380867994280a6))


### Fixes

* address bugs found in source-code review ([81b6995](https://github.com/2giosangmitom/sqmeow.nvim/commit/81b699587af19663e91121029cf51465a640690c))
* **edit:** let undo take back a deleted row ([e680cdd](https://github.com/2giosangmitom/sqmeow.nvim/commit/e680cddfedef10518fd7a5e4a892f1505a8fbc67))
* kill timed-out exec commands and read unclaimed values raw ([588ef75](https://github.com/2giosangmitom/sqmeow.nvim/commit/588ef759192e4c310e957cf29048ee0fff8cca7f))
* **postgres:** fall back when a server has no read-only sessions ([ba02602](https://github.com/2giosangmitom/sqmeow.nvim/commit/ba0260259fd8dc395d51d853cff521c016283c73))


### Refactoring

* add reusable table component ([c1bc5a8](https://github.com/2giosangmitom/sqmeow.nvim/commit/c1bc5a89d684a6b9b28638203f6d6fc4ac0a765c))
* **table:** simplify table component and fix cell bugs ([#21](https://github.com/2giosangmitom/sqmeow.nvim/issues/21)) ([6127c9f](https://github.com/2giosangmitom/sqmeow.nvim/commit/6127c9f9d97b8338c3009ea8ec3589b8851070e0))

## [2.1.0](https://github.com/2giosangmitom/sqmeow.nvim/compare/v2.0.0...v2.1.0) (2026-09-15)


### Features

* add a read-only checkbox to the connection dialog ([399c193](https://github.com/2giosangmitom/sqmeow.nvim/commit/399c193c4dcd64e50226f010392f0297a1150efa))
* add delete connection ([ce410bc](https://github.com/2giosangmitom/sqmeow.nvim/commit/ce410bc9916a174c1a54256d98011fbc25a1fca8))
* add SQL export, row duplication, defaults and a structure view ([30bea21](https://github.com/2giosangmitom/sqmeow.nvim/commit/30bea219feb2058fc6947cf59987c885d1465230))
* batch SQL export, SQL expression values and wider DuckDB editing ([4143701](https://github.com/2giosangmitom/sqmeow.nvim/commit/4143701267b1054d293f22e47ea32554e4dd8608))
* confirm destructive statements and add read-only connections ([cad3ee8](https://github.com/2giosangmitom/sqmeow.nvim/commit/cad3ee89cd0a18e13a0cbf1d9557843a686072f6))
* edit DuckDB results in the grid ([61caf98](https://github.com/2giosangmitom/sqmeow.nvim/commit/61caf98c17c36d9db0dceca2611dc4fb8213ff11))
* edit rows of joined, filtered and sorted results ([7da7060](https://github.com/2giosangmitom/sqmeow.nvim/commit/7da7060b549048deec5df6cca6b1719d43935014))
* filter results with a typed WHERE and ORDER BY ([3e184f2](https://github.com/2giosangmitom/sqmeow.nvim/commit/3e184f25f129f0e56c3e55687625e792b41f81aa))
* filter, sort and edit results, and copy them to the clipboard ([#9](https://github.com/2giosangmitom/sqmeow.nvim/issues/9)) ([b9527e2](https://github.com/2giosangmitom/sqmeow.nvim/commit/b9527e26177a4e21b75f9954061547b2f017e6ff))
* **filter:** filter Redis, ScyllaDB and closed-connection results in the bar ([bd8435f](https://github.com/2giosangmitom/sqmeow.nvim/commit/bd8435fb31bfce57bd9e6e9143cbf48bc1edf0e5))
* keep a result per statement, return inserted rows, and extend the structure view ([290523b](https://github.com/2giosangmitom/sqmeow.nvim/commit/290523bb0cf279caafd4b2fb228cb2a030a45694))
* lift limits across connections, editing, results, filtering and the drawer ([9b19a5e](https://github.com/2giosangmitom/sqmeow.nvim/commit/9b19a5eb5657e1c8247f25d5f0b0c19e676e693d))
* show query errors in the result buffer instead of diagnostics ([c84503c](https://github.com/2giosangmitom/sqmeow.nvim/commit/c84503c99829e4b242118d46dd943871de24e0d8))
* support DuckDB ([c3d4d9c](https://github.com/2giosangmitom/sqmeow.nvim/commit/c3d4d9c8399ac34fd2b26c1567ad05f6e526416a))
* support ScyllaDB and Cassandra ([dee59f0](https://github.com/2giosangmitom/sqmeow.nvim/commit/dee59f0ce830dab93eee3fa6c46e7dc303995314))
* **view:** filter held rows by a WHERE condition and an ORDER BY list ([efc511b](https://github.com/2giosangmitom/sqmeow.nvim/commit/efc511b706172237999f78671739bed52b5c0e32))


### Fixes

* **core:** fix tunnel test ([fc5d4e7](https://github.com/2giosangmitom/sqmeow.nvim/commit/fc5d4e75b5a859faee5d029ff11fc23af0b78a2e))
* drop create scratchpads for specific connection ([fc1afdd](https://github.com/2giosangmitom/sqmeow.nvim/commit/fc1afdd0c486a2144abbee29e4981506ac0c03c8))
* **edit:** write each side of a self-join through its own key ([39473ad](https://github.com/2giosangmitom/sqmeow.nvim/commit/39473ad7f3e596623db5a319ee480d92984d8c07))
* let the form's keys work from an open field ([edf69f5](https://github.com/2giosangmitom/sqmeow.nvim/commit/edf69f5a0a819f2979470ccd43c2e26380e513e0))
* **redis:** keep TTLs, delete list elements by position and refuse taken names ([5cb9c92](https://github.com/2giosangmitom/sqmeow.nvim/commit/5cb9c925b0f04d0e0037ff77d61a54908e8cb618))
* **scylla:** refuse an added row whose key is already stored ([8c9065c](https://github.com/2giosangmitom/sqmeow.nvim/commit/8c9065cd96675fa68ae584741848d44ce16edc12))
* split, edit, cancel and read SQL results reliably ([#11](https://github.com/2giosangmitom/sqmeow.nvim/issues/11)) ([65fcc7f](https://github.com/2giosangmitom/sqmeow.nvim/commit/65fcc7ffe988fa25e89db102420aafec2716eef7))
* **sqlite:** keep a view over a self-join read-only ([7088c02](https://github.com/2giosangmitom/sqmeow.nvim/commit/7088c025209181736f1c3c84b586247c7d77bde5))
* stop a DuckDB query cancelled before it starts ([f05fae3](https://github.com/2giosangmitom/sqmeow.nvim/commit/f05fae3993eed6473b1b88c42fbb5bb66b2feb89))


### Refactoring

* remove ponytail comments ([514593d](https://github.com/2giosangmitom/sqmeow.nvim/commit/514593d9b9fe4ad3315f40350950362e4c7aca98))
* trim verbose comments and remove dead code ([ccef876](https://github.com/2giosangmitom/sqmeow.nvim/commit/ccef87694599fc41fef1f46414543d0245daaef8))


### Documentation

* correct the README and add a release badge ([eb52780](https://github.com/2giosangmitom/sqmeow.nvim/commit/eb52780aa61e3ec4eec19f7ac6b32e803cf7fc92))
* describe filtering Redis, ScyllaDB and closed-connection results ([dbcbd45](https://github.com/2giosangmitom/sqmeow.nvim/commit/dbcbd454b7f4bdca53c2b8907592c46335966c49))
* improve documents ([338bc48](https://github.com/2giosangmitom/sqmeow.nvim/commit/338bc489138f1ff175c5d8e100f64f88dd268f78))
* improve keymap document [skip ci] ([d5e103b](https://github.com/2giosangmitom/sqmeow.nvim/commit/d5e103b5d62a333b5bcc8807b9a785f1fe3ca602))

## [2.0.0](https://github.com/2giosangmitom/sqmeow.nvim/compare/v1.0.2...v2.0.0) (2026-09-13)


### ⚠ BREAKING CHANGES

* `:Sqmeow` opens only the drawer and the result window, and `:Sqmeow scratch` and `api.scratchpad()` now prompt for a name instead of opening a scratchpad named after the connection.
* drop layout config, ship only one
* protocol version 2. `core.path` is now the plugin's data directory, not a path to the engine binary. The `connections`, `core.auto_install`, `query.history_file` and `ui.result.border` options are removed. nui.nvim is required.

### Features

* add MongoDB support ([9bb5800](https://github.com/2giosangmitom/sqmeow.nvim/commit/9bb5800ad8f36b0015395540c0cef1e50479efae))
* add Redis adapter ([3118be4](https://github.com/2giosangmitom/sqmeow.nvim/commit/3118be4ac2099907438cf5de4e2070abd0a34e1d))
* add Redis adapter ([0b69f5b](https://github.com/2giosangmitom/sqmeow.nvim/commit/0b69f5b6b4b26ba911ab725f4a54f6321d6c6d43))
* auto history reload ([9c493c7](https://github.com/2giosangmitom/sqmeow.nvim/commit/9c493c74ebdd9b6bc5f2778b2b765053d55b6286))
* connection string, row detail popup and key marks ([b36376e](https://github.com/2giosangmitom/sqmeow.nvim/commit/b36376e67047216abca32c88e773b057261f14e6))
* create scratchpads on demand from the drawer ([1110c80](https://github.com/2giosangmitom/sqmeow.nvim/commit/1110c80698ac95e69f3148fb71de01aed528acf0))
* draw results in Lua and keep query results in the log ([7b8c8c9](https://github.com/2giosangmitom/sqmeow.nvim/commit/7b8c8c988587b94dbae5e5ea3d109ac7c7a460f3))
* drop layout config, ship only one ([df02005](https://github.com/2giosangmitom/sqmeow.nvim/commit/df02005e5bb9b1b5825350085f78ae67af2de9d5))
* drop render crate and move rendering works to lua ([d84b293](https://github.com/2giosangmitom/sqmeow.nvim/commit/d84b293b7b83f8d4a1efd967ef1cad678ea3979a))
* export dialog replaces result yanks ([6f95e97](https://github.com/2giosangmitom/sqmeow.nvim/commit/6f95e971104a5169b4fe469a798500ccda8c9670))
* improve connect db UX ([4b300ef](https://github.com/2giosangmitom/sqmeow.nvim/commit/4b300ef5f5afb198b42f29e28b41e8d715005e9c))
* list every database when the database field is empty ([e6685d2](https://github.com/2giosangmitom/sqmeow.nvim/commit/e6685d2e421d1e4e3e8242f998b70cd576fa2d40))
* list every database when the database field is empty ([fad0b95](https://github.com/2giosangmitom/sqmeow.nvim/commit/fad0b952bcd6c377958679b6589948f6421aad46))
* **redis:** show JSON documents and test against Dragonfly ([57915a4](https://github.com/2giosangmitom/sqmeow.nvim/commit/57915a41b54e15df2b5143af3bfe3b9cda804006))
* remove bold highlight, show active db on winbar of result buf ([cc647b1](https://github.com/2giosangmitom/sqmeow.nvim/commit/cc647b188956e20d3d4a3813f4ebf932d85075db))


### Fixes

* **mysql:** show TIMESTAMP columns instead of an unsupported cell ([5ec3b4b](https://github.com/2giosangmitom/sqmeow.nvim/commit/5ec3b4bbfb00a920227e6e8d8b6dbfe7a62ba079))
* resolve lua-language-server diagnostics ([6b816c2](https://github.com/2giosangmitom/sqmeow.nvim/commit/6b816c22a94015dceffd7f91cb3902428844f8de))


### Refactoring

* improve codebase architecture ([0f25d95](https://github.com/2giosangmitom/sqmeow.nvim/commit/0f25d95a7d138299a033cbca46483727b8347c49))


### Documentation

* list the supported databases in the README ([fdae64d](https://github.com/2giosangmitom/sqmeow.nvim/commit/fdae64d1979d7eeda4fa5da369328fe63f50f885))
* update README ([b0ad5ad](https://github.com/2giosangmitom/sqmeow.nvim/commit/b0ad5adb922d2cbaf95876d3dd1d07570bb20ab4))
* update README ([116d20a](https://github.com/2giosangmitom/sqmeow.nvim/commit/116d20ae674c146ed6e3e982920f9209ca8743e6))

## [1.0.2](https://github.com/2giosangmitom/sqmeow.nvim/compare/v1.0.1...v1.0.2) (2026-09-12)


### Fixes

* **install:** download musl binary for linux ([d392c95](https://github.com/2giosangmitom/sqmeow.nvim/commit/d392c95630833d3c67fc9aec79e0ee15b517f3b9))

## [1.0.1](https://github.com/2giosangmitom/sqmeow.nvim/compare/v1.0.0...v1.0.1) (2026-09-12)


### Fixes

* **install:** don't freeze editor while download Rust binary ([097ae52](https://github.com/2giosangmitom/sqmeow.nvim/commit/097ae528abc6ea69c060eb269eaf2f7e32fce6c3))


### Documentation

* **readme:** use latest stable release ([fdee840](https://github.com/2giosangmitom/sqmeow.nvim/commit/fdee840d8d93e1a1c2cb39dfd3bf8ab07cc2e7ac))

## 1.0.0 (2026-09-12)


### ⚠ BREAKING CHANGES

* one self-contained client, no plugin integrations
* one configurable set of Nerd Font icons

### Features

* add and edit connections through a dialog ([c317bd3](https://github.com/2giosangmitom/sqmeow.nvim/commit/c317bd33a448588438354877fc813644649982dc))
* channel between the plugin and the Rust engine ([9ca7830](https://github.com/2giosangmitom/sqmeow.nvim/commit/9ca783093b8baeace063d388f20adefb007b7523))
* colour the drawer's expand markers ([266589c](https://github.com/2giosangmitom/sqmeow.nvim/commit/266589c3964819ec004dfe666eed90b84282abee))
* group a schema into tables, views, functions and procedures ([bc03edb](https://github.com/2giosangmitom/sqmeow.nvim/commit/bc03edb445cd6e86eec0319a8b9748e74db980cf))
* keep the query log across restarts ([5f89ead](https://github.com/2giosangmitom/sqmeow.nvim/commit/5f89ead5f03905803d2407235304e153509370d6))
* name and edit connections ([c2d8210](https://github.com/2giosangmitom/sqmeow.nvim/commit/c2d8210be74f299a33d12dcafcada09adcea39b4))
* nerd font icons, scratchpads in the drawer, and a picker fix ([37f86b6](https://github.com/2giosangmitom/sqmeow.nvim/commit/37f86b6a463df4e6b439555624aaf2ba267ab517))
* one configurable set of Nerd Font icons ([3f6fc75](https://github.com/2giosangmitom/sqmeow.nvim/commit/3f6fc75f86ea5cf1fe0f4abd3277e949287aead5))
* one self-contained client, no plugin integrations ([7ed08b8](https://github.com/2giosangmitom/sqmeow.nvim/commit/7ed08b8da370dfa9666110e8c3ae1c1973af7625))
* pickers, statusline, icons, and notifications ([1605b75](https://github.com/2giosangmitom/sqmeow.nvim/commit/1605b75936822ce43f35b0312b6184c6f37040c9))
* PostgreSQL and MySQL adapters, and connection sources ([04505bd](https://github.com/2giosangmitom/sqmeow.nvim/commit/04505bd43bfee1f7c9e7caf14016b327a1536d3f))
* query SQLite end to end ([0a760b3](https://github.com/2giosangmitom/sqmeow.nvim/commit/0a760b3be4c3bcbb2f59f4180533bb5632422704))
* rename a scratchpad from the drawer ([8f63891](https://github.com/2giosangmitom/sqmeow.nvim/commit/8f63891e118720d5da26291f7047971eee559811))
* say and choose which database a query runs on ([4f9c925](https://github.com/2giosangmitom/sqmeow.nvim/commit/4f9c92575a534653e727b26ee7ec96c95d91e983))
* schema drawer and the keymap system ([7596de6](https://github.com/2giosangmitom/sqmeow.nvim/commit/7596de68d8a493efee8f073f042dae8e6f1acae9))
* scratchpads, row detail, export, and a query log ([4ec3ad2](https://github.com/2giosangmitom/sqmeow.nvim/commit/4ec3ad20c7dbc5084fe1d777deb0234ce900228a))


### Fixes

* ask for a connection name instead of deriving one ([e675af8](https://github.com/2giosangmitom/sqmeow.nvim/commit/e675af8e69a6152a11d0a761d1807e4d74999b5e))
* connect the MySQL tests as root ([d9b0b3e](https://github.com/2giosangmitom/sqmeow.nvim/commit/d9b0b3e1ed6ac41829d7a724c1f1c412d789a0f6))
* let lualine find the component by name ([d4257b6](https://github.com/2giosangmitom/sqmeow.nvim/commit/d4257b6b09dcc658347f61857aab2604a5ad3266))
* one job per drawer key ([2fcf591](https://github.com/2giosangmitom/sqmeow.nvim/commit/2fcf5918c0268eff354ec62a79c07fb5dea19aa3))
* open scratchpads in an editing window, and allow deleting them ([9179faa](https://github.com/2giosangmitom/sqmeow.nvim/commit/9179faa1f1e0137aead940ce149edf738ce45516))
* refresh the count on a heading along with what it counts ([80c4a12](https://github.com/2giosangmitom/sqmeow.nvim/commit/80c4a125feb51d8a3e12d5fc682ad0e62658821b))


### Refactoring

* one buffer for the whole result grid ([4d8d39d](https://github.com/2giosangmitom/sqmeow.nvim/commit/4d8d39d515abefc4cc99a315a8ca0ede6fd9c4c3))


### Documentation

* a README written for people who want to use it ([4a4642a](https://github.com/2giosangmitom/sqmeow.nvim/commit/4a4642a7672c135a59f3004c71d70daa5812552f))
* add preview image ([935eb98](https://github.com/2giosangmitom/sqmeow.nvim/commit/935eb98315c83dc4726777505ebaa3a054d4b4c2))
* generated help, the protocol contract, and prebuilt releases ([edc3f74](https://github.com/2giosangmitom/sqmeow.nvim/commit/edc3f7419e006ee8be3a56b3ff6ff3c3ab973692))
