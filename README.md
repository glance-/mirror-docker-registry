mirror-docker-registry.sh
=========================
A simple little tool to mirror one docker registry over to another.

Whats special about this tool?
------------------------------
It's as far as I know the only one which can do registry-to-registry copy
without involving the local dockerd.

It also verifies that if the copy is needed or not, or which bits needs
copying instead of just blindly pushing all data.
