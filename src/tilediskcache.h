#ifndef TILEDISKCACHE_H
#define TILEDISKCACHE_H

#include <QObject>
#include <QString>
#include <QHash>
#include <QSet>

class QNetworkAccessManager;
class QNetworkReply;

// Дисковый кэш тайлов подложки НСПД, которые рисует свой QML Image, а не
// плагин QtLocation. QML-кэш Image живёт только в памяти и сбрасывается
// при смене кадра экспорта — снимок успевает схватить серые клетки.
// Ответы серверов часто приходят с Cache-Control, который штатный
// QNetworkDiskCache не сохраняет, поэтому файл пишется своим кодом.
class TileDiskCache : public QObject
{
    Q_OBJECT
public:
    explicit TileDiskCache(QObject *parent = nullptr);

    // file:///... если кадр уже лежит на диске. Иначе запускает
    // загрузку и возвращает пустую строку; по завершении — tileStored.
    Q_INVOKABLE QString localSource(const QString &url);
    Q_INVOKABLE bool hasFailed(const QString &url) const;

signals:
    void tileStored(const QString &url);
    void tileFailed(const QString &url);

private:
    QString hashName(const QString &url) const;
    QString existingPath(const QString &url) const;
    void startDownload(const QString &url);
    void finishDownload(const QString &url, QNetworkReply *reply);

    QNetworkAccessManager *m_nam;
    QString m_dir;
    QSet<QString> m_inflight;
    QSet<QString> m_failed;
    int m_storesSincePrune;
    int m_warnings = 0;
    bool m_sslLogged = false;
};

#endif // TILEDISKCACHE_H
