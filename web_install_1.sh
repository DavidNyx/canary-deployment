#!/bin/bash

set -e

sudo -s
yum update -y
yum install -y httpd
cd /var/www/html
echo "This is version 1.0!" > /var/www/html/index.html
systemctl enable httpd 
systemctl start httpd