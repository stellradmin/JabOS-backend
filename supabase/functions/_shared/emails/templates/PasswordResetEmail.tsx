import React from 'npm:react@18.2.0';
import { Button, Heading, Section, Text } from 'npm:@react-email/components@0.0.22';
import { BaseLayout } from './BaseLayout.tsx';
import { emailTheme } from '../theme.ts';

interface PasswordResetProps {
  readonly name?: string;
  readonly resetUrl: string;
  readonly expiresInMinutes?: number;
  readonly unsubscribeUrl: string;
}

export const PasswordResetEmail: React.FC<PasswordResetProps> = ({
  name,
  resetUrl,
  expiresInMinutes = 30,
  unsubscribeUrl,
}) => {
  const firstName = name?.split(' ')[0] || 'Stellr member';
  return (
    <BaseLayout
      previewText={`Reset your Stellr password, ${firstName}`}
      headline="Password reset"
      unsubscribeUrl={unsubscribeUrl}
    >
      <Heading className={emailTheme.heading}>Secure your account</Heading>
      <Section className="space-y-4">
        <Text className={emailTheme.bodyText}>
          Someone (hopefully you) requested a password reset for the Stellr account tied to this email.
        </Text>
        <Button href={resetUrl} className={emailTheme.primaryButton}>
          Create a new password
        </Button>
        <Text className={emailTheme.mutedText}>
          This link expires in {expiresInMinutes} minutes. If you didn’t request a reset, ignore this email.
        </Text>
      </Section>
    </BaseLayout>
  );
};
