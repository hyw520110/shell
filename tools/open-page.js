const { chromium } = require('@playwright/test');

(async () => {
  // Launch the browser
  const browser = await chromium.launch({ headless: false });
  
  // Create a new page
  const page = await browser.newPage();
  
  // Navigate to the specified URL
  await page.goto('http://192.168.1.103:5173/pages/merchant/shop/index');
  
  console.log('Page opened successfully. Press Ctrl+C to close.');
  
  // Keep the page open
  await new Promise(resolve => {
    // Wait for user to press Ctrl+C to close
    process.on('SIGINT', async () => {
      console.log('\nClosing browser...');
      await browser.close();
      process.exit(0);
    });
  });
})();