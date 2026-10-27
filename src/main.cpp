#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>

#include "appsettings.h"
#include "exportfilehelper.h"
#include "tilediskcache.h"
#include "logconsole.h"
#include "cadastralhttp.h"

#ifndef APP_VERSION
#define APP_VERSION "0.0.0"
#endif

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setApplicationName("KadBuffer");
    app.setOrganizationName("KadBuffer");
    app.setApplicationVersion(QStringLiteral(APP_VERSION));

    QQmlApplicationEngine engine;

    // Встроенная консоль (F12): перехватываем сообщения Qt/QML раньше
    // загрузки QML, чтобы в буфере оказались и ошибки старта.
    LogConsole logConsole;
    logConsole.installMessageHandler();

    AppSettings appSettings;
    ExportFileHelper exportFileHelper;
    CadastralHttp cadastralHttp;
    // После setApplicationName: каталог кэша — CacheLocation приложения.
    TileDiskCache tileDiskCache;
    engine.rootContext()->setContextProperty("appSettings", &appSettings);
    engine.rootContext()->setContextProperty("tileDiskCache", &tileDiskCache);
    engine.rootContext()->setContextProperty("exportFileHelper", &exportFileHelper);
    engine.rootContext()->setContextProperty("logConsole", &logConsole);
    engine.rootContext()->setContextProperty("cadastralHttp", &cadastralHttp);
    engine.rootContext()->setContextProperty("appVersion", QStringLiteral(APP_VERSION));

    engine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    if (engine.rootObjects().isEmpty())
        return -1;

    return app.exec();
}
