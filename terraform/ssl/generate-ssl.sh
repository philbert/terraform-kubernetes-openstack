#!/bin/bash

openssl genrsa -out ssl/ca-key.pem 2048
openssl req -x509 -new -nodes -key ssl/ca-key.pem -days 10000 -out ssl/ca.pem -subj '/CN=kubernetes-ca'
openssl genrsa -out ssl/admin-key.pem 2048
openssl req -new -key ssl/admin-key.pem -out ssl/admin.csr -subj '/CN=kubernetes-admin'
openssl x509 -req -in ssl/admin.csr -CA ssl/ca.pem -CAkey ssl/ca-key.pem -CAcreateserial -out ssl/admin.pem -days 365
