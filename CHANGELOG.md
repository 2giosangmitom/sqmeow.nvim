# Changelog

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
