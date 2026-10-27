#include "logconsole.h"

#include <QDateTime>
#include <QMutexLocker>
#include <QThread>

#include <cstdio>

namespace {

// Какой экземпляр получает строки — LogConsole создаётся в main.cpp
// ровно один и живёт до выхода; статики достаточно (без singleton-
// функции создания, чтобы не плодить скрытое состояние).
LogConsole *g_instance = nullptr;

// Защита от рекурсии: emit textChanged() → QML-биндинг → возможный
// qWarning из QML → снова handler → append. Внутри обработчика повторный
// вызов не перезаписывает буфер, но и не теряет вывод в stderr.
thread_local bool t_inHandler = false;

QString levelTag(QtMsgType type)
{
    switch (type) {
    case QtDebugMsg: return QStringLiteral("DEBUG");
    case QtInfoMsg: return QStringLiteral("INFO");
    case QtWarningMsg: return QStringLiteral("WARN");
    case QtCriticalMsg: return QStringLiteral("CRIT");
    case QtFatalMsg: return QStringLiteral("FATAL");
    }
    return QStringLiteral("LOG");
}

} // namespace

LogConsole::LogConsole(QObject *parent) : QObject(parent)
{
    g_instance = this;
}

QString LogConsole::text() const
{
    QMutexLocker lock(&_mutex);
    return _text;
}

void LogConsole::installMessageHandler()
{
    qInstallMessageHandler(&LogConsole::handler);
}

void LogConsole::handler(QtMsgType type, const QMessageLogContext &, const QString &message)
{
    const QString line = QStringLiteral("[%1] %2: %3")
            .arg(QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss.zzz")),
                 levelTag(type), message);

    // Сохраняем привычное поведение Qt: всё видно и в консоли запуска.
    std::fprintf(stderr, "%s\n", line.toUtf8().constData());
    std::fflush(stderr);

    if (t_inHandler || !g_instance)
        return;
    t_inHandler = true;
    g_instance->append(line);
    t_inHandler = false;
}

void LogConsole::append(const QString &line)
{
    {
        QMutexLocker lock(&_mutex);
        _lines.append(line);
        while (_lines.size() > MaxLines)
            _lines.removeFirst();
        _text = _lines.join(QLatin1Char('\n'));
    }
    emit textChanged();
}

void LogConsole::clear()
{
    {
        QMutexLocker lock(&_mutex);
        _lines.clear();
        _text.clear();
    }
    emit textChanged();
}
