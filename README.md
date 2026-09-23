Simple one string install:

sh <(wget -O - https://github.com/Trogvars/podkop_subsync/raw/refs/heads/main/install-podkop-sub-sync.sh)

Then add subscription link to config (check section name for edit):

/etc/config/podkop-sub-sync

config sync 'main'

        option url 'https://subscription.url/'

And start daemon:

/etc/init.d/podkop-sub-sync enable

/etc/init.d/podkop-sub-sync start
