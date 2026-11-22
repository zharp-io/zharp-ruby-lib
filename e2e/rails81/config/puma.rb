# Cluster mode with the app loaded before the fork: what Zharp must survive.
workers 2
threads 2, 4
preload_app!
port 3000
