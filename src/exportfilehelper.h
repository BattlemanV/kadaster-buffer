#ifndef EXPORTFILEHELPER_H
#define EXPORTFILEHELPER_H

#include <QObject>
#include <QString>
#include <QVariantMap>

// Файловые операции экспорта для QML. Сами отчёты (.xlsx/.docx) строит
// qml/components/Reports.js — здесь только упаковка их частей в zip.
class ExportFileHelper : public QObject
{
    Q_OBJECT
public:
    explicit ExportFileHelper(QObject *parent = nullptr) : QObject(parent) {}

    // Документы/KadBuffer/exports — создаётся при первом обращении.
    Q_INVOKABLE QString reportsDir() const;

    // Файл существует и открыт другой программой (Excel/Word держат
    // открытый документ на запись) — перезаписать его не получится.
    Q_INVOKABLE bool isFileLocked(const QString &path) const;

    // Открыть файл программой по умолчанию.
    Q_INVOKABLE bool openInDocViewer(const QString &path) const;

    // Инструкция пользователя — manual.html рядом с exe (кнопка «?», F1).
    Q_INVOKABLE bool openManual() const;

    // Системный диалог «Сохранить как» (Windows, GetSaveFileNameW — без
    // Qt Widgets/Dialogs). suggestedPath — путь по умолчанию (папка + имя),
    // filterName — подпись типа файла, ext — расширение без точки.
    // Пустая строка — пользователь отменил.
    Q_INVOKABLE QString chooseSavePath(const QString &title, const QString &suggestedPath,
                                       const QString &filterName, const QString &ext) const;

    // Записать zip-архив (OOXML: .xlsx/.docx) из {путь_в_архиве: текст}.
    // Тексты пишутся в UTF-8, сжатие deflate через zlib из QtCore.
    // Пустая строка — успех, иначе текст ошибки для статуса.
    Q_INVOKABLE QString writeZip(const QString &path, const QVariantMap &entries) const;
};

#endif // EXPORTFILEHELPER_H
