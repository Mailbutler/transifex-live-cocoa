Kamusi
======

Cocoa Localization Framework for OS X, which uses Transifex ( http://www.transifex.com ) as its basis. Kamusi (Suaheli for 'dictionary') consists of few Cocoa classes doing all the work.

Kamusi Framework
-------
The Kamusi Cocoa framework is meant to be used by application developers to let their application be localized by its users. The framework checks whether there is a Transifex project registered for the current application and uses the cloud localizations directly for presentation in the user's preferred language.

As a result, Kamusi allows to localize the active application on the fly. This approach has the advantage that an application can be localized quickly by its user base.

Version Compatibility Of Installed Translation Bundles
-------
To avoid stale or incompatible runtime translations after app updates, Kamusi now validates installed translation bundles before using them.

How it works:
1. Downloaded translations are installed into the `KamusiTranslations` directory in Application Support.
2. On successful install, Kamusi writes a `Metadata.plist` into that directory.
3. The metadata contains:
	- `BundleIdentifier`
	- `BundleVersion` (`CFBundleVersion`)
	- `BundleShortVersion` (`CFBundleShortVersionString`)
4. At runtime, Kamusi only uses translations when metadata matches the currently running app:
	- bundle identifier must match
	- build version must match
	- if short version is present in metadata, it must also match

Fallback behavior:
1. If metadata is missing or does not match, Kamusi ignores installed translations.
2. Localization then falls back to the app bundle resources.

Operational note:
1. Older translation directories created before metadata support are intentionally ignored.
2. After the next successful pull + install cycle on the current app version, metadata is created and translations become active again.