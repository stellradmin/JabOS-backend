// deno-lint-ignore-file no-explicit-any
// Helper function to send a push notification using Expo's push service.
// Assumes the pushToken is a valid ExpoPushToken.

interface PushNotificationData {
  type: string;
  [key: string]: any; // Allow other custom data properties
}

export async function sendPushNotification(
  pushToken: string,
  title: string,
  body: string,
  data?: PushNotificationData,
): Promise<void> {
  if (!pushToken) {
    console.warn('No push token provided, skipping notification.');
    return;
  }

  // Validate ExpoPushToken format (basic check)
  if (!pushToken.startsWith('ExponentPushToken[') && !pushToken.startsWith('ExpoPushToken[')) {
    console.warn(`Invalid push token format: ${pushToken}. Skipping notification.`);
    return;
  }

  const message = {
    to: pushToken,
    sound: 'default' as const, // Ensure 'default' is treated as a literal type
    title: title,
    body: body,
    data: data || {},
    _displayInForeground: true, // Optional: to display notification when app is in foreground (Expo Go specific behavior)
  };

  try {
    const response = await fetch('https://exp.host/--/api/v2/push/send', {
      method: 'POST',
      headers: {
        'Accept': 'application/json',
        'Accept-encoding': 'gzip, deflate',
        'Content-Type': 'application/json',
        // 'Authorization': `Bearer ${Deno.env.get('EXPO_ACCESS_TOKEN')}` // Include if using an Expo Access Token
      },
      body: JSON.stringify(message),
    });

    const responseText = await response.text(); // Read response text first for better error diagnosis
    
    if (!response.ok) {
      // Try to parse error if JSON, otherwise use text
      let errorDetails = responseText;
      try {
        const errorJson = JSON.parse(responseText);
        if (errorJson && errorJson.errors) {
          errorDetails = JSON.stringify(errorJson.errors);
        }
      } catch (_e) {
        // Not a JSON error, use raw text
      }
      throw new Error(`Failed to send push notification. Status: ${response.status}. Details: ${errorDetails}`);
    }

    // Expo's API returns a ticket or an error.
    // A 200 OK response means the request was successfully received by Expo's server,
    // but not necessarily that the push notification was successfully delivered to the device.
    // You might want to check the response body for ticket IDs or error details.
    // Example: {"data": [{"status": "ok", "id": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"}]}
    // Example error: {"errors": [{"code": "VALIDATION_ERROR", "message": "\"to\" must be a valid ExponentPushToken."}]}
    
    const responseData = JSON.parse(responseText); // Assuming responseText is valid JSON if response.ok
    if (responseData.data && Array.isArray(responseData.data)) {
      responseData.data.forEach((ticket: any) => {
        if (ticket.status === 'error') {
          console.error(`Error in push notification ticket for token ${pushToken}:`, ticket);
          // Potentially handle specific errors, e.g., 'DeviceNotRegistered' to remove the token from DB
        } else if (ticket.status === 'ok') {
          console.log('Push notification sent successfully:', ticket.id);
        }
      });
    }


  } catch (error) {
    console.error(`Error sending push notification to ${pushToken}:`, error);
    // Do not let notification failure block the main Edge Function logic,
    // but log it thoroughly.
  }
}

// Example Usage (for testing this function directly if needed, not for import):
/*
if (import.meta.main) {
  // Replace with a real ExpoPushToken for testing
  const testToken = "ExponentPushToken[xxxxxxxxxxxxxxxxxxxxxx]"; 
  if (testToken.includes("xxxx")) {
    console.warn("Please replace testToken with a real ExpoPushToken to test.");
  } else {
    sendPushNotification(
      testToken,
      "Test Title from Deno Helper",
      "This is a test body from Deno helper! 🚀",
      { type: "test_notification", customId: "12345" }
    ).then(() => console.log("Test push notification sent successfully!"))
     .catch(e => console.error("Test push failed:", e));
  }
}
*/
