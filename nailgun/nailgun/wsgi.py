import os
import sys

curdir = os.path.dirname(__file__)
sys.path.insert(0, curdir)

from nailgun.settings import settings
from nailgun.application import application, apps
from nailgun.logger import logger, HTTPLoggerMiddleware


def build_middleware(app):
    middleware_list = [
        HTTPLoggerMiddleware,
    ]

    logger.debug('Initialize middleware: %s' %
                 (map(lambda x: x.__name__, middleware_list)))

    return app(*middleware_list)


def run_server(debug=False, **kwargs):
    for urls in apps:
        for url, handler in urls.urls:
            application.add_url_rule(
                url,
                view_func=handler.as_view(str(handler))
            )
    application.run(
        debug=debug,
        host=kwargs.get("host") or settings.LISTEN_ADDRESS,
        port=kwargs.get("port") or int(settings.LISTEN_PORT)
    )


def appstart(keepalive=False):
    logger.info("Fuel-Web {0} SHA: {1}\nFuel SHA: {2}".format(
        settings.PRODUCT_VERSION,
        settings.COMMIT_SHA,
        settings.FUEL_COMMIT_SHA
    ))

    from nailgun.rpc import threaded
    from nailgun.keepalive import keep_alive

    if keepalive:
        logger.info("Running KeepAlive watcher...")
        keep_alive.start()

    if not settings.FAKE_TASKS:
        if not keep_alive.is_alive() \
                and not settings.FAKE_TASKS_AMQP:
            logger.info("Running KeepAlive watcher...")
            keep_alive.start()
        rpc_process = threaded.RPCKombuThread()
        logger.info("Running RPC consumer...")
        rpc_process.start()
    logger.info("Running WSGI app...")

    #wsgifunc = build_middleware(app.wsgifunc)

    run_server(
        host=settings.LISTEN_ADDRESS,
        port=int(settings.LISTEN_PORT),
        debug=True
    )

    logger.info("Stopping WSGI app...")
    if keep_alive.is_alive():
        logger.info("Stopping KeepAlive watcher...")
        keep_alive.join()
    if not settings.FAKE_TASKS:
        logger.info("Stopping RPC consumer...")
        rpc_process.join()
    logger.info("Done")
