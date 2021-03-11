#!/bin/sh

S_PRV_OUT=server_prv.key
S_PUB_OUT=server_pub.key
C_PRV_OUT=client_prv.key
C_PUB_OUT=client_pub.key

wg genkey | tee $S_PRV_OUT | wg pubkey > $S_PUB_OUT
wg genkey | tee $C_PRV_OUT | wg pubkey > $C_PUB_OUT
