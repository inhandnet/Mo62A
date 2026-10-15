#!/usr/bin/env python3
"""Check the system Python dependencies used by TI U-Boot packaging."""
import yaml
import yamllint
from yamllint import config, linter
from jsonschema import validate
import elftools
import cryptography
from Cryptodome.PublicKey import RSA
from Cryptodome.Hash import SHA256
from Cryptodome.Signature import pkcs1_15

print("TI U-Boot Python dependencies are available.")
