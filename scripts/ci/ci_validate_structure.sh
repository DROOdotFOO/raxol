#!/bin/bash
# CI Validation Script for Raxol - Minimal Version
set -e

echo "==================================="
echo "Raxol CI Structure Validation"
echo "==================================="

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

CHECKS_PASSED=0
CHECKS_FAILED=0

echo ""
echo "1. File Structure Check..."
echo "---------------------------"

# Check key files exist
if [ -f "lib/raxol/terminal/graphics/kitty_protocol.ex" ]; then
    echo -e "${GREEN}✓${NC} Kitty Protocol exists"
    ((CHECKS_PASSED++))
else
    echo -e "${RED}✗${NC} Kitty Protocol missing"
    ((CHECKS_FAILED++))
fi

if [ -d "test/raxol/terminal/graphics" ]; then
    echo -e "${GREEN}✓${NC} Graphics tests directory exists"
    ((CHECKS_PASSED++))
else
    echo -e "${RED}✗${NC} Graphics tests directory missing"
    ((CHECKS_FAILED++))
fi

echo ""
echo "2. Code Quality Check..."
echo "-------------------------"

# Check if statement count
IF_COUNT=$(grep -r "^\s*if\s" lib/ --include="*.ex" --include="*.exs" | grep -v "# if" | wc -l)
echo "If statement count: $IF_COUNT"
if [ "$IF_COUNT" -le 2 ]; then
    echo -e "${GREEN}✓${NC} If statement target met (≤2)"
    ((CHECKS_PASSED++))
else
    echo -e "${RED}✗${NC} Too many if statements: $IF_COUNT (target: ≤2)"
    ((CHECKS_FAILED++))
fi

echo ""
echo "==================================="
echo "Validation Summary"
echo "==================================="
echo -e "Checks Passed: ${GREEN}$CHECKS_PASSED${NC}"
echo -e "Checks Failed: ${RED}$CHECKS_FAILED${NC}"

if [ $CHECKS_FAILED -eq 0 ]; then
    echo -e "\n${GREEN}OK: all validation checks passed${NC}"
    exit 0
else
    echo -e "\n${RED}FAIL: validation failed with $CHECKS_FAILED errors${NC}"
    exit 1
fi