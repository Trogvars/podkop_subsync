Simple one string install:

sh <(wget -O - https://github.com/Trogvars/podkop_subsync/raw/refs/heads/main/install-podkop-sub-sync.sh)

Then add sbuscription link to config:

/etc/config/podkop-sub-sync

config sync 'main'

        option url 'https://subscription.url/'

And start daemon:

/etc/init.d/podkop-sub-sync enable
/etc/init.d/podkop-sub-sync start
