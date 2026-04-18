import { CanActivate, ExecutionContext, Injectable, UnauthorizedException } from '@nestjs/common';
import { FirebaseService } from '../../../config/firebase/firebase.service';

@Injectable()
export class AuthGuard implements CanActivate {
  constructor(private readonly firebaseService: FirebaseService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest();
    const authHeader = request.headers.authorization;

    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      throw new UnauthorizedException('Valid Bearer token must be provided');
    }

    const token = authHeader.split('Bearer ')[1];

    try {
      const decodedToken = await this.firebaseService.getAuth().verifyIdToken(token);
      request['user'] = {
        ...decodedToken,
        uid: decodedToken.uid,
        email: decodedToken.email,
      };
      return true;
    } catch (error) {
      throw new UnauthorizedException('Invalid firebase token');
    }
  }
}
