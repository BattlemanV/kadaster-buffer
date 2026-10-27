#include "cadastralhttp.h"
#include "nspdssl.h"

#include <QNetworkRequest>
#include <QUrl>
#include <QSslError>
#include <QStringList>
#include <QDebug>

CadastralHttp::CadastralHttp(QObject *parent)
    : QObject(parent)
{
}

int CadastralHttp::get(const QString &url, const QString &referer,
                        const QString &userAgent, int timeoutMs)
{
    return _send(url, referer, userAgent, timeoutMs, QByteArray(), false);
}

int CadastralHttp::post(const QString &url, const QString &referer,
                        const QString &userAgent, int timeoutMs,
                        const QString &body)
{
    return _send(url, referer, userAgent, timeoutMs, body.toUtf8(), true);
}

int CadastralHttp::_send(const QString &url, const QString &referer,
                         const QString &userAgent, int timeoutMs,
                         const QByteArray &body, bool isPost)
{
    const QUrl u(url);
    if (!u.isValid() || u.host().isEmpty())
        return 0;

    const int id = _nextId++;

    QNetworkRequest request(u);
    // Системные корневые + сертификат Минцифры (см. nspdssl.h).
    request.setSslConfiguration(nspdSslConfiguration());
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    if (!userAgent.isEmpty())
        request.setRawHeader(QByteArray("User-Agent"), userAgent.toUtf8());
    if (!referer.isEmpty())
        request.setRawHeader(QByteArray("Referer"), referer.toUtf8());
    request.setRawHeader(QByteArray("Accept"),
                          QByteArray("application/json, text/plain, */*"));

    QNetworkReply *reply;
    if (isPost) {
        request.setHeader(QNetworkRequest::ContentTypeHeader,
                          QStringLiteral("application/json"));
        // WAF НСПД смотрит не только на Referer: браузер к этому
        // эндпоинту шлёт и Origin. Берём его из самого URL, чтобы
        // не зашивать хост в код.
        request.setRawHeader(QByteArray("Origin"),
                             (u.scheme() + QStringLiteral("://") + u.host()).toUtf8());
        reply = _nam.post(request, body);
    } else {
        reply = _nam.get(request);
    }

    Pending p;
    p.reply = reply;

    if (timeoutMs > 0) {
        QTimer *timer = new QTimer(this);
        timer->setSingleShot(true);
        timer->setInterval(timeoutMs);
        connect(timer, &QTimer::timeout, this, [this, id]() { _onTimeout(id); });
        p.timer = timer;
        p.timeoutMs = timeoutMs;
        timer->start();
    }

    _pending.insert(id, p);

    // SSL-ошибки: в Qt 5 у QNetworkReply нет геттера sslErrors(), ошибка
    // приходит сигналом. Запоминаем текст, чтобы сообщить вызывающему
    // (у старой ПКК, например, сертификат просрочен).
    connect(reply, &QNetworkReply::sslErrors, this,
            [this, id, reply](const QList<QSslError> &errors) {
        if (errors.isEmpty() || !_pending.contains(id)) return;
        // Перечисляем ВСЕ ошибки, а не только первую: к истёкшему сроку
        // нередко примешана ещё одна, и без списка этого не увидеть.
        QStringList all;
        for (const QSslError &e : errors)
            all << e.errorString();
        // Цепочка — кто подписал: Минцифры, антивирус с проверкой https,
        // корпоративный прокси. Без неё причину не понять.
        const QString chain = peerChainText(reply);
        _pending[id].sslError = all.join(QStringLiteral("; "))
                + (chain.isEmpty() ? QString() : QStringLiteral("; цепочка: ") + chain);
    }, Qt::DirectConnection);

    connect(reply, &QNetworkReply::finished, this, [this, id, reply]() {
        _onReplyFinished(id, reply);
    });

    return id;
}

void CadastralHttp::_onTimeout(int id)
{
    Pending p = _pending.value(id);
    if (!p.reply)
        return;
    // Помечаем таймаут и обрываем запрос: обработчик finished увидит флаг
    // и отдаст именно "таймаут", а не "операция прервана".
    Pending &ref = _pending[id];
    ref.timedOut = true;
    p.reply->abort();
}

void CadastralHttp::_onReplyFinished(int id, QNetworkReply *reply)
{
    Pending p = _pending.value(id);
    if (!p.reply)
        return;
    const bool timedOut = p.timedOut;
    const int timeoutMs = p.timeoutMs;
    if (p.timer) {
        p.timer->stop();
        p.timer->deleteLater();
    }
    _pending.remove(id);

    const QByteArray data = reply->readAll();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QString contentType = reply->header(QNetworkRequest::ContentTypeHeader).toString();

    // SSL-ошибки не игнорируем: просроченный сертификат — это ошибка
    // источника, а не повод обходить проверку. Текст ошибки уходит
    // вызывающему, чтобы он показал его в статусе.
    if (!p.sslError.isEmpty()) {
        const QString err = p.sslError;
        reply->deleteLater();
        emit finished(id, 0, QString(), contentType, QStringLiteral("SSL: ") + err);
        return;
    }

    if (timedOut) {
        reply->deleteLater();
        emit finished(id, 0, QString(), contentType,
                      QStringLiteral("таймаут %1 с").arg(timeoutMs / 1000));
        return;
    }

    if (status == 0 && reply->error() != QNetworkReply::NoError) {
        const QString err = reply->errorString();
        reply->deleteLater();
        emit finished(id, 0, QString(), contentType, err);
        return;
    }

    reply->deleteLater();
    emit finished(id, status, QString::fromUtf8(data), contentType, QString());
}
