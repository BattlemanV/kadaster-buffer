#ifndef APPSETTINGS_H
#define APPSETTINGS_H

#include <QObject>
#include <QSettings>
#include <QVariant>

// Настройки KadBuffer — ini-файл в профиле пользователя
// (%APPDATA%\KadBuffer\KadBuffer.ini). Сейчас там только вид слоёв
// карты (цвета, штриховка — ключи layers/*), поэтому вместо Q_PROPERTY
// на каждое значение — общий доступ по ключу.
class AppSettings : public QObject
{
    Q_OBJECT
public:
    explicit AppSettings(QObject *parent = nullptr)
        : QObject(parent)
        , m_settings(QSettings::IniFormat, QSettings::UserScope,
                     QStringLiteral("KadBuffer"), QStringLiteral("KadBuffer"))
    {}

    Q_INVOKABLE QVariant value(const QString &key, const QVariant &defaultValue = QVariant()) const
    { return m_settings.value(key, defaultValue); }
    Q_INVOKABLE void setValue(const QString &key, const QVariant &v)
    { m_settings.setValue(key, v); }

private:
    QSettings m_settings;
};

#endif // APPSETTINGS_H
