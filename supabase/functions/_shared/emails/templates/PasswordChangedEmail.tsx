import React from 'npm:react@18.2.0';
import { Heading, Section, Text } from 'npm:@react-email/components@0.0.22';
import { BaseLayout } from './BaseLayout.tsx';
import { emailTheme } from '../theme.ts';

interface PasswordChangedProps {
  readonly name?: string;
  readonly unsubscribeUrl: string;
}

export const PasswordChangedEmail: React.FC<PasswordChangedProps> = ({ name, unsubscribeUrl }) => {
  const firstName = name?.split(' ')[0] || 'Stellr member';
  return (
    <BaseLayout
      previewText={`Your Stellr password was updated, ${firstName}`}
      headline="Password updated"
      unsubscribeUrl={unsubscribeUrl}
    >
      <Heading className={emailTheme.heading}>Your password is updated</Heading>
      <Section className="space-y-4">
        <Text className={emailTheme.bodyText}>
          We wanted to let you know that your Stellr password was just changed.
        </Text>
        <Text className={emailTheme.bodyText}>
          If this wasn’t you, reset your password immediately from the login screen and contact support.
        </Text>
      </Section>
    </BaseLayout>
  );
};
