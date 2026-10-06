import Testing
@testable import SwimCore

/// The app locale's subprocess overrides — the pair that must beat a
/// localized user environment (the French-desktop git dates came from
/// gettext's LANGUAGE outranking LC_ALL, which is why BOTH keys exist).
/// AppLocale is a pure value: every fixture constructs its own, there
/// is no shared state to race.
struct AppLocaleTests {
    @Test func englishOverrides() {
        // The gettext fallback list is always id-derived; LC_ALL takes
        // the platform's guaranteed-present spelling (C.UTF-8 is
        // builtin glibc >= 2.35; en_US.UTF-8 is always on macOS).
        let overrides = AppLocale(id: "en").environmentOverrides
        #if canImport(Darwin)
        #expect(overrides["LC_ALL"] == "en_US.UTF-8")
        #else
        #expect(overrides["LC_ALL"] == "C.UTF-8")
        #endif
        #expect(overrides["LANGUAGE"] == "en_US:en")
    }

    @Test func bareLanguageDoublesItsCodeAsRegion() {
        #expect(AppLocale(id: "fr").environmentOverrides == [
            "LC_ALL": "fr_FR.UTF-8",
            "LANGUAGE": "fr_FR:fr",
        ])
        #expect(AppLocale(id: "de").environmentOverrides == [
            "LC_ALL": "de_DE.UTF-8",
            "LANGUAGE": "de_DE:de",
        ])
    }

    @Test func regionQualifiedIdPassesThrough() {
        // "pt_BR" must not double into "pt_BR_PT_BR" — a configured
        // region is honored verbatim; the LANGUAGE list falls back to
        // the bare language.
        #expect(AppLocale(id: "pt_BR").environmentOverrides == [
            "LC_ALL": "pt_BR.UTF-8",
            "LANGUAGE": "pt_BR:pt",
        ])
    }

    @Test func englishVariantsTakeGuaranteedSpelling() {
        // "en_GB" must NOT become "en_GB.UTF-8": a regional spelling
        // may not exist on the box, and an invalid LC_ALL does not
        // degrade gracefully (setlocale()-calling children die). Any
        // English id takes the guaranteed-present spelling; the
        // LANGUAGE list keeps the regional form.
        let overrides = AppLocale(id: "en_GB").environmentOverrides
        #if canImport(Darwin)
        #expect(overrides["LC_ALL"] == "en_US.UTF-8")
        #else
        #expect(overrides["LC_ALL"] == "C.UTF-8")
        #endif
        #expect(overrides["LANGUAGE"] == "en_GB:en")
    }

    @Test func childEnvironmentAppliesOverridesOverInherited() {
        // What a French shell hands down must lose the locale vars and
        // keep everything else.
        let french = ["LANG": "fr_FR.UTF-8", "LC_ALL": "", "LANGUAGE": "fr_FR:ru:en"]
        let child = AppLocale(id: "en").childEnvironment(over: french)
        #if canImport(Darwin)
        #expect(child["LC_ALL"] == "en_US.UTF-8")
        #else
        #expect(child["LC_ALL"] == "C.UTF-8")
        #endif
        #expect(child["LANGUAGE"] == "en_US:en")
        #expect(child["LANG"] == "fr_FR.UTF-8")
    }

    @Test func defaultIsEnglish() {
        #expect(AppLocale.current.id == "en")
    }
}
