import React from 'npm:react@18.2.0';
import { Button, Heading, Section, Text } from 'npm:@react-email/components@0.0.22';
import { BaseLayout } from './BaseLayout.tsx';
import { emailTheme } from '../theme.ts';

interface EmailVerificationProps {
  readonly name?: string;
  readonly verificationUrl: string;
  readonly verificationCode?: string;
  readonly unsubscribeUrl: string;
}

export const EmailVerificationEmail: React.FC<EmailVerificationProps> = ({
  name,
  verificationUrl,
  verificationCode,
  unsubscribeUrl,
}) => {
  const firstName = name?.split(' ')[0] || 'Friend';
  return (
    <BaseLayout
      previewText={`Verify your Stellr account, ${firstName}`}
      headline="Confirm your Stellr account"
      unsubscribeUrl={unsubscribeUrl}
    >
      <Heading className={emailTheme.heading}>Just one more tap</Heading>
      <Section className="space-y-4">
        <Text className={emailTheme.bodyText}>
          Hey {firstName}, tap the button below to activate your Stellr profile.
        </Text>
        <Button href={verificationUrl} className={emailTheme.primaryButton}>
          Verify your email
        </Button>
        {verificationCode && (
          <Text className={emailTheme.mutedText}>
            Prefer to verify manually? Use this code: <strong>{verificationCode}</strong>
          </Text>
        )}
      </Section>
    </BaseLayout>
  );
};
