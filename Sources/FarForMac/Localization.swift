import Foundation

/// App-local preference: never changes AppleLanguages or the system locale.
enum UILanguage: String, CaseIterable {
    case russian = "ru", english = "en"
}

@MainActor
enum L10n {
    static var language: UILanguage {
        get { UILanguage(rawValue: AppPreferences.defaults.string(forKey: "ui.language") ?? "ru") ?? .russian }
        set { AppPreferences.defaults.set(newValue.rawValue, forKey: "ui.language") }
    }

    /// Only known UI copy is translated. Paths, filenames, command IDs and user content are not localized.
    static func text(_ source: String) -> String {
        guard language == .english else { return source }
        if let value = english[source] { return value }
        // Function-bar prefixes remain stable keyboard hints.
        if source.first == "F", let separator = source.range(of: "  ") {
            let title = String(source[separator.upperBound...])
            if let translated = english[title] { return String(source[..<separator.upperBound]) + translated }
        }
        return source
    }

    private static let english: [String: String] = [
        "Командная строка — Cmd+Enter": "Command line — Cmd+Enter",
        "Панели / терминал — Ctrl+O": "Panels / terminal — Ctrl+O",
        "Интерактивный shell": "Interactive shell",
        "Настроить меню и ассоциации…": "Configure menu and associations…",
        "История команд — Alt+F8": "Command history — Alt+F8",
        "История просмотра — Alt+F11": "Viewer history — Alt+F11",
        "История редактора": "Editor history",
        "История папок — Alt+F12": "Folder history — Alt+F12",
        "Описание файла…": "File description…",
        "Группы сортировки…": "Sort groups…",
        "Файловая панель": "File panel",
        "Дерево каталогов · Ctrl+T": "Folder tree · Ctrl+T",
        "Информационная панель · Ctrl+L": "Information panel · Ctrl+L",
        "Быстрый просмотр · Ctrl+Q": "Quick view · Ctrl+Q",
        "Сравнить каталоги…": "Compare folders…",
        "Добавить выбранное во временную соседнюю панель": "Add selected to opposite temporary panel",
        "Убрать из временной панели (без удаления файлов)": "Remove from temporary panel (keep files)",
        "Перейти к исходной папке": "Go to original folder",
        "Сохранить сессию панелей": "Save panel session",
        "Быстрый поиск по имени": "Quick find by name",
        "Следующее совпадение": "Next match",
        "Предыдущее совпадение": "Previous match",
        "Фильтр текущей папки": "Filter current folder",
        "Показать / скрыть скрытые файлы": "Show / hide hidden files",
        "Открыть этот путь в соседней панели": "Open this path in opposite panel",
        "Взять путь соседней панели": "Use opposite panel path",
        "Пометить и перейти вниз": "Mark and move down",
        "Отметить по маске…": "Mark by mask…",
        "Снять пометки по маске…": "Unmark by mask…",
        "Восстановить прошлые пометки — Ctrl+M": "Restore previous marks — Ctrl+M",
        "Отметить то же расширение": "Mark same extension",
        "Снять пометки с того же расширения": "Unmark same extension",
        "Отметить то же имя без расширения": "Mark same base name",
        "Снять пометки с того же имени": "Unmark same name",
        "Инвертировать файлы": "Invert file marks",
        "Инвертировать всё, включая папки": "Invert all marks including folders",
        "Инвертировать файлы и снять папки": "Invert files and unmark folders",
        "Отметить всё": "Mark all",
        "Снять все пометки": "Clear all marks",
        "Группы масок…": "Mask groups…",
        "Автоматизация": "Automation",
        "Расширения": "Extensions",
        "Команды текущего окна…": "Commands for current window…",
        "Начать запись макроса": "Start recording macro",
        "Завершить запись…": "Finish recording…",
        "Отменить запись": "Discard recording",
        "Воспроизвести макрос…": "Play macro…",
        "Остановить макрос": "Stop macro",
        "Назначить клавишу…": "Assign shortcut…",
        "Включить / выключить привязки": "Enable / disable bindings",
        "Удалить макрос…": "Delete macro…",
        "Импортировать макросы…": "Import macros…",
        "Экспортировать макросы…": "Export macros…",
        "История ошибок…": "Error history…",
        "Запустить расширение по описанию…": "Run extension from manifest…",
        "Остановить расширение": "Stop extension",
        "SHA-256 текста": "Text SHA-256",
        "Статистика выбранных файлов": "Selected file statistics",
        "Просмотр JSON с форматированием": "Formatted JSON viewer",
        "EditCase: ASCII ПРОПИСНЫЕ": "EditCase: ASCII UPPERCASE",
        "EditCase: ASCII строчные": "EditCase: ASCII lowercase",
        "Align: выравнивание ASCII до 75 колонок": "Align: wrap ASCII to 75 columns",
        "Новый файл — Shift+F4": "New file — Shift+F4",
        "Сохранить как…": "Save As…",
        "Восстановить черновики редактора…": "Recover editor drafts…",
        "Массовое переименование…": "Batch rename…",
        "Свойства и права…": "Properties and permissions…",
        "Создать символическую ссылку…": "Create symbolic link…",
        "Создать жёсткую ссылку…": "Create hard link…",
        "Удалить безвозвратно…": "Delete permanently…",
        "Копировать объект под курсором…": "Copy item under cursor…",
        "Подключиться…": "Connect…",
        "Отключиться": "Disconnect",
        "Удалённая папка…": "Remote folder…",
        "Обновить / подключиться повторно": "Refresh / reconnect",
        "Отменить сетевую операцию": "Cancel network operation",
        "Продолжить скачивание": "Resume download",
        "Сбросить незавершённое скачивание": "Discard incomplete download",
        "Открыть как архив · Ctrl+PageDown": "Open as archive · Ctrl+PageDown",
        "Закрыть архив": "Close archive",
        "Создать ZIP / TAR…": "Create ZIP / TAR…",
        "Извлечь выбранное…": "Extract selected…",
        "Добавить выбранное в соседний архив…": "Add selected to opposite archive…",
        "Удалить выбранное из архива…": "Delete selected from archive…",
        "Отменить архивную операцию": "Cancel archive operation",
        "Файлы": "Files", "Операции": "Operations", "Поиск": "Search", "Правка": "Edit",
        "Команды": "Commands", "Панели": "Panels", "Пометки": "Marks", "Окно": "Window",
        "Сеть": "Network", "Архив": "Archive", "Помощь": "Help", "Меню": "Menu", "Выход": "Quit",
        "Домой": "Home", "Диски": "Volumes", "Терминал": "Terminal", "Скрытые": "Hidden",
        "Польз. меню": "User menu", "Пользовательское меню": "User menu", "Просмотр": "View",
        "Редактировать": "Edit", "Копия": "Copy", "Перенос": "Move", "Папка": "Folder", "Корзина": "Trash",
        "Копировать…": "Copy…", "Переместить…": "Move…", "Создать папку…": "Create folder…",
        "В Корзину…": "Move to Trash…", "Переименовать…": "Rename…",
        "О FarForMac": "About FarForMac", "Скрыть FarForMac": "Hide FarForMac", "Выйти из FarForMac": "Quit FarForMac",
        "Отменить": "Undo", "Повторить": "Redo", "Вырезать": "Cut", "Копировать": "Copy", "Вставить": "Paste", "Выделить всё": "Select All",
        "Закрыть окно": "Close Window", "Свернуть": "Minimize", "Готово": "Ready", "Файловый менеджер": "File manager",
        "Имя": "Name", "Размер": "Size", "Изменён": "Modified", "Расширение": "Extension", "Создан": "Created", "Доступ": "Accessed",
        "Последний доступ": "Last accessed", "Владелец": "Owner", "Описание": "Description", "Права POSIX": "POSIX permissions",
        "Отмена": "Cancel", "Применить": "Apply", "Сохранить": "Save", "Закрыть": "Close", "Открыть": "Open", "Да": "Yes", "Нет": "No",
        "Назад": "Back", "Вперёд": "Forward", "Обновить": "Refresh", "Вернуться к папке": "Return to folder",
        "Перейти к пути…": "Go to path…", "Выбрать папку…": "Choose folder…", "Настройки активной панели…": "Active panel settings…",
        "Открыть Терминал здесь": "Open Terminal here", "Показать в Finder": "Show in Finder",
        "Фильтр в этой папке  ⌘F": "Filter this folder  ⌘F", "Фильтр результатов  ⌘F": "Filter results  ⌘F",
        "Быстрый поиск  ⌥буква · ⌃↩ далее · Esc закрыть": "Quick find  ⌥letter · ⌃↩ next · Esc close",
        "Space  пометка    Tab  панель    ⌘L  путь    ⌘F  фильтр": "Space  mark    Tab  panel    ⌘L  path    ⌘F  filter",
        "Очередь и журнал…": "Queue and history…", "Отменить все ожидающие и текущую": "Cancel queued and current operations",
        "Найти файлы… — ⌥F7": "Find files… — ⌥F7", "Вернуться из результатов к папке": "Return from results to folder",
        "По возрастанию": "Ascending", "Папки первыми": "Folders first", "Учитывать регистр": "Case sensitive",
        "Сортировать по": "Sort by", "Режим": "Mode", "Вид и сортировка": "Display and sorting",
        "Настройки сохраняются отдельно для каждой панели.": "Settings are saved separately for each panel.",
        "Краткий — только имя": "Brief — name only", "Полный — основные сведения": "Full — main details", "Свои колонки": "Custom columns",
        "Файл": "File", "Символическая ссылка": "Symbolic link", "Помечено": "Marked", "Не помечено": "Not marked",
        "Левая панель": "Left panel", "Правая панель": "Right panel", "Путь": "Path", "Фильтр": "Filter", "Быстрый поиск": "Quick find",
        "Доступность и язык…": "Accessibility and language…", "Доступность и язык": "Accessibility and language",
        "Язык": "Language", "Размер текста": "Text size", "Повышенный контраст": "High contrast",
        "Настройки применятся после перезапуска приложения.": "Settings take effect after restarting the app.",
        "Обычный (100%)": "Standard (100%)", "Крупный (125%)": "Large (125%)", "Очень крупный (150%)": "Extra large (150%)"
    ]
}
