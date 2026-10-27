#ifndef CADASTRALHTTP_H
#define CADASTRALHTTP_H

#include <QObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QHash>
#include <QTimer>

// HTTP-запросчик для кадастровых источников.
//
// Зачем он нужен, если в QML есть XMLHttpRequest: QML-XMLHttpRequest
// ВЫРЕЗАЕТ заголовки Referer и Cookie из запроса (проверено вживую на
// локальном эхо-сервере: заголовок, выставленный через
// setRequestHeader("Referer", ...), до сервера не доходит, а User-Agent
// подменяется на "Mozilla/5.0"). При этом WAF nspd.gov.ru без заголовка
// Referer отдаёт 403 — проверено вживую: без Referer 403 в 10/10
// запросов, с Referer "https://nspd.gov.ru/map?thematic=PKK" — 200 в
// 10/10. То есть из QML до НСПД достучаться нельзя в принципе.
//
// Через QNetworkAccessManager заголовок уходит как есть. Заодно здесь
// можно задать таймаут (в QML-XHR его нет вовсе) и не зависеть от
// поведения XHR при редиректах.
//
// Ошибки SSL НЕ игнорируются: у части хостов (старая ПКК
// pkk.rosreestr.ru) сертификат просрочен — такой источник честно
// отдаёт ошибку, и цепочка переходит к следующему провайдеру.
class CadastralHttp : public QObject
{
    Q_OBJECT
public:
    explicit CadastralHttp(QObject *parent = nullptr);

    // GET-запрос. referer/userAgent — необязательные заголовки.
    // timeoutMs — таймаут в миллисекундах (<=0 — без таймаута).
    // Возвращает внутренний id запроса (0 — запрос не запущен).
    Q_INVOKABLE int get(const QString &url, const QString &referer,
                        const QString &userAgent, int timeoutMs);

    // POST с JSON-телом. Нужен для НСПД
    // /api/geoportal/v1/intersects — поиска объектов, пересекающихся
    // с переданной геометрией (замена умершего bbox-поиска ПКК).
    Q_INVOKABLE int post(const QString &url, const QString &referer,
                         const QString &userAgent, int timeoutMs,
                         const QString &body);

signals:
    // status — HTTP-код (0 — сетевая ошибка, таймаут или SSL-ошибка),
    // body — тело ответа, contentType — заголовок Content-Type,
    // error — текст ошибки (пусто при успехе).
    void finished(int id, int status, const QString &body,
                  const QString &contentType, const QString &error);

private:
    struct Pending
    {
        QNetworkReply *reply = nullptr;
        QTimer *timer = nullptr;
        int timeoutMs = 0;
        bool timedOut = false;
        QString sslError;
    };

    QNetworkAccessManager _nam;
    QHash<int, Pending> _pending;
    int _nextId = 1;

    // Общая часть get/post: заголовки, таймаут, учёт в _pending.
    int _send(const QString &url, const QString &referer, const QString &userAgent,
              int timeoutMs, const QByteArray &body, bool isPost);

    void _onReplyFinished(int id, QNetworkReply *reply);
    void _onTimeout(int id);
};

#endif // CADASTRALHTTP_H
