cmake_minimum_required(VERSION 3.5)
project(kadbuffer C CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# AutoMoc "предопределения компилятора" падает на этой связке CMake/MinGW,
# не влияя на реальную компиляцию.
set(CMAKE_AUTOMOC_COMPILER_PREDEFINES OFF)

find_package(Qt5Core REQUIRED)
find_package(Qt5Qml REQUIRED)
find_package(Qt5Quick REQUIRED)
find_package(Qt5Positioning REQUIRED)
find_package(Qt5Location REQUIRED)
find_package(Qt5Network REQUIRED)

qt5_add_resources(QT_RESOURCES qml/qml.qrc resources/certs.qrc)

# Единая точка версии приложения — файл VERSION в корне репозитория.
# Используется здесь (ресурс Windows exe + APP_VERSION для C++/QML) и
# установщиком (installer/kadbuffer.iss читает тот же файл).
file(STRINGS "${CMAKE_SOURCE_DIR}/VERSION" APP_VERSION_RAW LIMIT_COUNT 1)
string(STRIP "${APP_VERSION_RAW}" APP_VERSION)
string(REPLACE "." ";" APP_VERSION_PARTS "${APP_VERSION}")
list(GET APP_VERSION_PARTS 0 APP_VERSION_MAJOR)
list(GET APP_VERSION_PARTS 1 APP_VERSION_MINOR)
list(GET APP_VERSION_PARTS 2 APP_VERSION_PATCH)

# windres.exe — строго из пары к нашему компилятору (Qt/Tools/mingw810_64):
# посторонний MinGW на PATH даёт "i386 architecture ... incompatible".
if(WIN32 AND MINGW)
    get_filename_component(_mingw_bin_dir ${CMAKE_CXX_COMPILER} DIRECTORY)
    if(EXISTS "${_mingw_bin_dir}/windres.exe")
        set(CMAKE_RC_COMPILER "${_mingw_bin_dir}/windres.exe" CACHE FILEPATH "" FORCE)
    endif()
endif()
enable_language(RC)
file(TO_NATIVE_PATH "${CMAKE_SOURCE_DIR}/resources/app.ico" APP_ICON_PATH_NATIVE)
string(REPLACE "\\" "\\\\" APP_ICON_PATH "${APP_ICON_PATH_NATIVE}")
configure_file(
    ${CMAKE_SOURCE_DIR}/resources/version.rc.in
    ${CMAKE_CURRENT_BINARY_DIR}/version.rc
    @ONLY)

add_executable(${PROJECT_NAME} WIN32
    src/main.cpp
    src/appsettings.h
    src/tilediskcache.cpp
    src/exportfilehelper.cpp
    src/logconsole.cpp
    src/cadastralhttp.h
    src/cadastralhttp.cpp
    src/nspdssl.h
    src/nspdssl.cpp
    ${QT_RESOURCES}
    ${CMAKE_CURRENT_BINARY_DIR}/version.rc)

target_compile_definitions(${PROJECT_NAME} PRIVATE APP_VERSION="${APP_VERSION}")

target_link_libraries(${PROJECT_NAME}
    Qt5::Gui Qt5::Qml Qt5::Quick Qt5::Positioning Qt5::Location Qt5::Network)
# comdlg32 — системный диалог «Сохранить как» (ExportFileHelper::chooseSavePath).
if(WIN32)
    target_link_libraries(${PROJECT_NAME} comdlg32)
endif()
target_include_directories(${PROJECT_NAME} PRIVATE ${CMAKE_CURRENT_BINARY_DIR})

# Инструкция пользователя — рядом с exe (кнопка «?» / F1 открывает её).
add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_SOURCE_DIR}/docs/manual.html $<TARGET_FILE_DIR:${PROJECT_NAME}>/manual.html)

# Среда выполнения Visual C++ для OpenSSL (он собран MSVC 2017):
# vcruntime140.dll 14.28 + Universal CRT из Windows SDK 10.0.10240 —
# локальный актив в runtime/, не в git. Без него на машине без «Visual C++
# Redistributable» OpenSSL не грузится: «TLS initialization failed».
if(EXISTS "${CMAKE_SOURCE_DIR}/runtime")
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_SOURCE_DIR}/runtime $<TARGET_FILE_DIR:${PROJECT_NAME}>)
endif()

# OpenSSL 1.1 DLL для QSslSocket (тайлы НСПД, API НСПД — весь https).
# windeployqt их не копирует; локальный актив в openssl/, не в git.
if(EXISTS "${CMAKE_SOURCE_DIR}/openssl")
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_SOURCE_DIR}/openssl $<TARGET_FILE_DIR:${PROJECT_NAME}>)
endif()
