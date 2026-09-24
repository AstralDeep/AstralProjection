"""Declares the private resource namespace for AstralProjection's packaged contracts
(RESOURCE_NAMESPACE), addressed by name through resources.py's contract_root() rather
than a normal import.
"""

RESOURCE_NAMESPACE = "astralprojection.contract-resources/v1"

__all__ = ["RESOURCE_NAMESPACE"]
