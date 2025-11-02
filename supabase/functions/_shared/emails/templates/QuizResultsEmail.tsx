import React from 'npm:react@18.2.0';
import { Heading, Section, Text, Button } from 'npm:@react-email/components@0.0.22';
import { BaseLayout } from './BaseLayout.tsx';
import { emailTheme } from '../theme.ts';

interface QuizResultsEmailProps {
  readonly name?: string;
  readonly sunSign: string;
  readonly moonSign: string;
  readonly risingSign: string;
  readonly personalityInsights: string[];
  readonly compatibilityHighlights: string[];
  readonly downloadLink: string;
  readonly shareLink: string;
  readonly unsubscribeUrl: string;
}

export const QuizResultsEmail: React.FC<QuizResultsEmailProps> = ({
  name,
  sunSign,
  moonSign,
  risingSign,
  personalityInsights,
  compatibilityHighlights,
  downloadLink,
  shareLink,
  unsubscribeUrl,
}) => {
  const firstName = name?.split(' ')[0] || 'Cosmic Explorer';
  return (
    <BaseLayout
      previewText={`✨ ${firstName}, your cosmic love language is ready`}
      headline="Your Stellr Cosmic Profile"
      unsubscribeUrl={unsubscribeUrl}
    >
      <Heading className={emailTheme.heading}>✨ {firstName}, your cosmic love language revealed</Heading>
      <Text className={`${emailTheme.bodyText} text-center`}>
        We mapped your chart using your birth data to surface how you love, connect, and attract matches.
      </Text>

      <Section className={`${emailTheme.card} text-center`}>
        <Text className={`${emailTheme.label} text-center`}>Core Trio</Text>
        <Text className={`${emailTheme.bodyText} mt-4 text-lg font-semibold text-[#f5d0fe]`}>Sun • {sunSign}</Text>
        <Text className={`${emailTheme.bodyText} mt-2 text-lg font-semibold text-[#f5d0fe]`}>
          Moon • {moonSign}
        </Text>
        <Text className={`${emailTheme.bodyText} mt-2 text-lg font-semibold text-[#f5d0fe]`}>
          Rising • {risingSign}
        </Text>
      </Section>

      <Section className={emailTheme.softCard}>
        <Text className={`${emailTheme.label} text-left`}>Signature Vibes</Text>
        {personalityInsights.map((insight) => (
          <Text key={insight} className={`${emailTheme.bodyText} mt-4`}>
            {insight}
          </Text>
        ))}
      </Section>

      <Section className={emailTheme.softCard}>
        <Text className={`${emailTheme.label} text-left`}>Who You Magnetize</Text>
        <ul className={emailTheme.listBare}>
          {compatibilityHighlights.map((highlight) => (
            <li key={highlight} className={emailTheme.bodyText}>
              {highlight}
            </li>
          ))}
        </ul>
      </Section>

      <Section className="text-center">
        <Button href={downloadLink} className={emailTheme.primaryButton}>
          Download Stellr to find your match
        </Button>
        <div className="my-8 flex justify-center">
          <div className={emailTheme.divider} style={{ margin: 0, width: '100%' }} />
        </div>
        <Button href={shareLink} className={emailTheme.secondaryButton}>
          Share your results
        </Button>
      </Section>
    </BaseLayout>
  );
};
