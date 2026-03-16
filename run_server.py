#!/usr/bin/env python3
"""Entry point to run the OSGSameCloudService server."""
import os

import uvicorn
from server.config import HOST, PORT

if __name__ == "__main__":
    dev_mode = os.getenv("OSGSC_ENV", "production") == "development"
    uvicorn.run("server.app:app", host=HOST, port=PORT, reload=dev_mode)
