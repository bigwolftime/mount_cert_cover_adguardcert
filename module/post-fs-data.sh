#!/system/bin/sh

exec > /data/local/tmp/adguardcert.log
exec 2>&1

set -x

# current shell directory
MODDIR=${0%/*}

set_context() {
    [ "$(getenforce)" = "Enforcing" ] || return 0

    default_selinux_context=u:object_r:system_file:s0
    selinux_context=$(ls -Zd $1 | awk '{print $1}')

    if [ -n "$selinux_context" ] && [ "$selinux_context" != "?" ]; then
        chcon -R $selinux_context $2
    else
        chcon -R $default_selinux_context $2
    fi
}

# Android hashes the subject to get the filename, field order is significant.
# (`openssl x509 -in ... -noout -hash`)
# AdGuard's certificate is "/C=EN/O=AdGuard/CN=AdGuard Personal CA".
# The filename is then <hash>.<n> where <n> is an integer to disambiguate
# different certs with the same hash (e.g. when the same cert is installed repeatedly).
# 
# Due to https://github.com/AdguardTeam/AdguardForAndroid/issues/2108
# 1. Retrieve the most recent certificate with our hash from the user store.
#    It is assumed that the last installed AdGuard's cert is the correct one.
# 2. Copy the AdGuard certificate to the system store under the name "<hash>.0". 
#    Note that some apps may ignore other certs.
# 3. Remove all certs with our hash from the `cacerts-removed` directory.
#    They get there if a certificate is "disabled" in the security settings.
#    Apps will reject certs that are in the `cacerts-removed`.
# AG_CERT_HASH=364618e0

# e.g. AG_CERT_FILE = /data/misc/user/0/cacerts-added/364618e0.0
# AG_CERT_FILE=$(ls /data/misc/user/*/cacerts-added/${AG_CERT_HASH}.* | (IFS=.; while read -r left right; do echo $right $left.$right; done) | sort -nr | (read -r left right; echo $right))

# Note: /data/misc/user/*/cacerts-removed is a directory for storing certificates that the user has deleted.
# When the user clicks "Clear Credentials" on the "Encryption and Credentials" page, the system will move the
# certificates installed by the user from /data/misc/user/0/cacerts-added to this directory for recovery when needed.
# rm -f /data/misc/user/*/cacerts-removed/${AG_CERT_HASH}.*

cp -f /data/misc/user/*/cacerts-added/* ${MODDIR}/system/etc/security/cacerts/
# change owner to root user (user: root, group: root)
chown -R 0:0 ${MODDIR}/system/etc/security/cacerts
set_context /system/etc/security/cacerts ${MODDIR}/system/etc/security/cacerts

# Android 14 support
# Since Magisk ignore /apex for module file injections, use non-Magisk way
if [ -d /apex/com.android.conscrypt/cacerts ]; then
    # Clone directory into tmpfs
    rm -f /data/local/tmp/adg-ca-copy
    mkdir -p /data/local/tmp/adg-ca-copy
    mount -t tmpfs tmpfs /data/local/tmp/adg-ca-copy
    cp -f /apex/com.android.conscrypt/cacerts/* /data/local/tmp/adg-ca-copy/

    # Do the same as in Magisk module
    cp -f /data/misc/user/*/cacerts-added/* /data/local/tmp/adg-ca-copy/
    chown -R 0:0 /data/local/tmp/adg-ca-copy
    set_context /apex/com.android.conscrypt/cacerts /data/local/tmp/adg-ca-copy

    # Mount directory inside APEX if it is valid, and remove temporary one.
    CERTS_NUM="$(ls -1 /data/local/tmp/adg-ca-copy | wc -l)"
    if [ "$CERTS_NUM" -gt 10 ]; then
        mount --bind /data/local/tmp/adg-ca-copy /apex/com.android.conscrypt/cacerts
        for pid in 1 $(pgrep zygote) $(pgrep zygote64); do
            nsenter --mount=/proc/${pid}/ns/mnt -- \
                /bin/mount --bind /data/local/tmp/adg-ca-copy /apex/com.android.conscrypt/cacerts
        done
    else
        echo "Cancelling replacing CA storage due to safety"
    fi
    umount /data/local/tmp/adg-ca-copy
    rmdir /data/local/tmp/adg-ca-copy
fi
