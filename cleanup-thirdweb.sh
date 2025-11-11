#!/bin/bash

# Script to remove all partial/broken thirdweb installations
# Run with: bash cleanup-thirdweb.sh

set -e

echo "🧹 Cleaning up thirdweb installations..."

# 1. Remove npx cache (where npx stores temporary packages)
echo "1. Removing npx cache..."
rm -rf ~/.npm/_npx 2>/dev/null || true
echo "   ✓ npx cache cleared"

# 2. Clear npm cache
echo "2. Clearing npm cache..."
npm cache clean --force 2>/dev/null || true
echo "   ✓ npm cache cleared"

# 3. Remove thirdweb from local node_modules (if installed but not in package.json)
echo "3. Checking local node_modules..."
if [ -d "node_modules/thirdweb" ]; then
    rm -rf node_modules/thirdweb
    echo "   ✓ Removed local thirdweb package"
else
    echo "   ✓ No local thirdweb package found"
fi

# 4. Remove global thirdweb installation (if any)
echo "4. Checking global installations..."
if npm list -g thirdweb &>/dev/null; then
    npm uninstall -g thirdweb 2>/dev/null || true
    echo "   ✓ Removed global thirdweb"
else
    echo "   ✓ No global thirdweb installation found"
fi

# 5. Verify cleanup
echo ""
echo "✅ Cleanup complete!"
echo ""
echo "Next steps:"
echo "  1. Try running: npx thirdweb@latest deploy -k YOUR_KEY"
echo "  2. Or use the npm script: npm run deploy -- -k YOUR_KEY"
echo ""

