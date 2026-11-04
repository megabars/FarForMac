# Accessibility and language

The application offers an app-local Russian/English preference, text scaling from 85% to 150%, and a high-contrast palette. Preferences use the application's own preference store; they do not alter macOS language, keyboard, appearance, or accessibility settings.

`L10n.text` translates an explicit catalog of common menu names, action buttons, toolbar labels, panel column headers, and filter hints. Command identifiers, shortcuts, filenames, paths, and editable user content remain unchanged. `UIAccessibility.apply` can be called repeatedly: it retains original control fonts and table row heights. Table content is excluded from string translation to protect filenames that happen to match UI words.

Coverage is intentionally partial: dynamic operation summaries, detailed error messages, archive/network workflows, command help, and many secondary dialogs still contain Russian text. Changing the language is not a claim that every screen is localized. New UI copy should be added to the explicit catalog and applied when constructing the view.

File rows expose name, file/folder/link type, and marked/unmarked state through `UIAccessibility.fileRow`. Marking is distinct from the native table cursor selection. Panel, path, filter, and quick-find controls need explicit localized accessibility labels. Native AppKit controls retain their normal accessibility roles and keyboard behavior.

## Manual verification

- Enable VoiceOver, navigate into each panel, move the cursor and toggle marks. Confirm the announced filename, type, and mark state change without relying on color.
- Use Tab and Shift-Tab to reach controls; Return applies dialogs and Escape cancels. Use application menu shortcuts for file operations when the keyboard's function keys control macOS hardware features.
- Switch Russian → English → Russian and check main menus, toolbar, column headers and common buttons. Confirm command actions and shortcuts remain identical.
- Apply text scales of 85%, 100%, and 150% twice. Confirm text does not grow cumulatively, table rows expand, and labels remain usable at the supported minimum window size.
- Enable high contrast and verify current-row focus and marked state remain apparent. Compare text, muted text, selection and focus colors in both panels.
- Open files named `Имя`, `Name`, and `Отмена`; confirm the displayed filename never changes with the UI language.

These manual checks require a running app and assistive technology. A successful build alone does not certify VoiceOver or full keyboard accessibility.

Appearance updates also scale editor/viewer `NSTextView` fonts and restore captured original foreground, background, and caret colors when high contrast is disabled. Only labels explicitly tagged `localized-label` participate in recursive label translation; editable data and other noneditable content are preserved. Automation and Extensions menus have explicit English catalog entries.

Verified on 2026-11-04 in the installed arm64 build: English/125%/high contrast, switching the panel's four-item mode popup and returning to Files, then restoring Russian/100%/normal contrast and reopening preferences. Image-only controls retain their native presentation; composite AppKit controls own their internal subviews. Regression smoke checks popup count/selection, image buttons and search/cancel cell titles. This does not establish the remaining VoiceOver or full scale/layout matrix.
