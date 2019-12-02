#!/bin/sh

dir=`dirname $0`

rsync -av --delete pkgbuild.com:public_html/quarry/x86_64/ "$dir"/../index/
