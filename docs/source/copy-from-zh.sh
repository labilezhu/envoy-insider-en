cp -r -l /home/labile/envoy-insider/docs/source/* /home/labile/envoy-insider-en/docs/source/

find `pwd` -name "*.md"  > /home/labile/envoy-insider-en/docs/source/o.sh

## Replace o.sh:
# /home/labile/envoy-insider/docs/source/(.+) -> rm /home/labile/envoy-insider-en/docs/source/$1;cp $0 /home/labile/envoy-insider-en/docs/source/$1


###########


find /home/labile/envoy-insider/docs/source/ -name "*.drawio.svg" > copy-drawio-from-zh.sh