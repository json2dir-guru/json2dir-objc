# json2dir-objc

json2dir in Objective-C: one file on the bare GNU Objective-C runtime (own root class, no Foundation, hand-written JSON parser).

    clang -fobjc-runtime=gcc -o json2dir json2dir.m -lobjc && ./json2dir < tree.json
