#ifndef LOGCONSOLE_H
#define LOGCONSOLE_H

#include <QObject>
#include <QString>
#include <QStringList>
#include <QMutex>

// Встроенная консоль отладки: перехватывает ВСЕ сообщения Qt (qDebug/
// qInfo/qWarning/qCritical, включая ошибки загрузки QML и console.log из
// QML), складывает их в ограниченный буфер и отдаёт в QML как одну
// строку text. Панель внизу окна (components/LogConsole.qml) показывает
// её, текст можно выделять и копировать — пользователь присылает вывод
// разработчику без запуска внешней консоли.
//
// Строки дополнительно пишутся в stderr (как обычно у Qt), поэтому
// поведение при запуске из терминала не меняется.
class LogConsole : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString text READ text NOTIFY textChanged)
public:
    explicit LogConsole(QObject *parent = nullptr);

    QString text() const;

    // Вешает глобальный обработчик сообщений Qt. Вызывать ДО загрузки
    // QML (main.cpp), иначе ранние ошибки загрузки не попадут в буфер.
    void installMessageHandler();

    // Добавить произвольную строку (в т.ч. из QML: logConsole.append(...)).
    Q_INVOKABLE void append(const QString &line);

    Q_INVOKABLE void clear();

signals:
    void textChanged();

private:
    static void handler(QtMsgType type, const QMessageLogContext &context, const QString &message);

    mutable QMutex _mutex;
    QStringList _lines;
    QString _text;

    // Ограничение буфера, чтобы длинная сессия не съела память.
    static const int MaxLines = 1000;
};

#endif // LOGCONSOLE_H
