"""org.freedesktop.FileManager1, answered by a terminal file manager.

Browsers' "show in folder" (and anything else that wants to reveal a file) calls
ShowItems on this bus name rather than consulting the inode/directory mime
association. This is the server for that name: it turns the call into a launcher
invocation, and the launcher is argv[1:] so the service file owns what runs.
"""

import asyncio
import subprocess
import sys
from urllib.parse import unquote, urlparse

from dbus_fast import BusType
from dbus_fast.aio import MessageBus
from dbus_fast.service import ServiceInterface, method

NAME = "org.freedesktop.FileManager1"
PATH = "/org/freedesktop/FileManager1"

# yazi opens one tab per path and caps out at nine.
MAX_TABS = 9


def local_paths(uris: list) -> list:
    parsed = [urlparse(uri) for uri in uris]
    return [unquote(p.path) for p in parsed if p.scheme == "file"][:MAX_TABS]


class FileManager1(ServiceInterface):
    def __init__(self, launcher: list):
        super().__init__(NAME)
        self.launcher = launcher

    def show(self, uris: list) -> None:
        paths = local_paths(uris)
        if paths:
            # Detached: the window outlives this call and must not be reaped here.
            subprocess.Popen([*self.launcher, *paths], start_new_session=True)

    # yazi given a file reveals it in its parent and given a directory opens
    # it, so ShowItems and ShowFolders are the same launch. The properties
    # dialog has no terminal equivalent; revealing the item is the closest.
    @method()
    def ShowFolders(self, uris: "as", startup_id: "s"):  # noqa: F722,F821
        self.show(uris)

    @method()
    def ShowItems(self, uris: "as", startup_id: "s"):  # noqa: F722,F821
        self.show(uris)

    @method()
    def ShowItemProperties(self, uris: "as", startup_id: "s"):  # noqa: F722,F821
        self.show(uris)


async def main(launcher: list) -> None:
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    bus.export(PATH, FileManager1(launcher))
    await bus.request_name(NAME)
    await bus.wait_for_disconnect()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
