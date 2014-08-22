#!/bin/sh

dir=`dirname $0`

rsync -av --delete celestia:packages/quarry/x86_64/ "$dir"/../index/
